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
#include <algorithm>
#include <chrono>
#include <mutex>
#include <unistd.h>

#if DEBUG
#include <mach/mach_time.h>
#include <os/lock.h>
// [CARDCLOCK] (MANIFOLD_CARDCLOCK_LOG=1; DEBUG; pre-ship removal, docs/BUGS.md; docs/CARD_CLOCK_FINDINGS.md). Measurement only, reads
// nothing but status. Once a second from the completion callback: the completed-frame count, the host time, the frame's completion
// timestamp (the SDK: locked to the system clock) and the output's hardware reference clock (the SDK: locked to the rate the hardware
// outputs frames). [CARDCLOCK-REF] at output start and once a minute: reference, clock adjustment and temperature.
namespace {
struct CardClockProbe {
    IDeckLinkStatus *status = nullptr; IDeckLinkStatistics *stats = nullptr;
    IDeckLinkProfileAttributes *attrs = nullptr; IDeckLinkConfiguration *config = nullptr;
};
CardClockProbe gCardClock;   // held for the process: a measurement build, env-gated
const bool kCardClockLog = getenv("MANIFOLD_CARDCLOCK_LOG") != nullptr;
#ifdef DEBUG
// [AUDIO-CORR] (MANIFOLD_AUDIO_CORR_LOG=1; DEBUG; pre-ship removal, docs/BUGS.md; docs/CARD_CLOCK_FINDINGS.md §10.16). Measurement only:
// one line per callback that schedules PCM, with the audio stream position of its first sample, the samples the card took, the anchor
// loop's correction and what it was (c: steering, a: anchor snap, r: resync), so each discontinuity on the wire can be matched to one.
const bool kAudioCorrLog = getenv("MANIFOLD_AUDIO_CORR_LOG") != nullptr;
#endif
double cardClockHostNow() {
    static mach_timebase_info_data_t tb = [] { mach_timebase_info_data_t t; mach_timebase_info(&t); return t; }();
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}
void cardClockAdopt(IDeckLink *device) {
    if (!kCardClockLog || gCardClock.status) return;
    device->QueryInterface(IID_IDeckLinkStatus, (void **)&gCardClock.status);
    device->QueryInterface(IID_IDeckLinkStatistics, (void **)&gCardClock.stats);
    device->QueryInterface(IID_IDeckLinkProfileAttributes, (void **)&gCardClock.attrs);
    device->QueryInterface(IID_IDeckLinkConfiguration, (void **)&gCardClock.config);
}
void cardClockLogReference(const char *when, IDeckLinkOutput *output) {
    if (!kCardClockLog) return;
    BMDReferenceStatus ref = 0; const HRESULT refHr = output->GetReferenceStatus(&ref);
    bool hasRef = false, canAdjust = false, refLocked = false, inLocked = false;
    int64_t refMode = 0, refFlags = 0, adjust = 0, refOut = 0, temp = 0;
    HRESULT hasHr = E_FAIL, canHr = E_FAIL, lockHr = E_FAIL, modeHr = E_FAIL, flagsHr = E_FAIL, inHr = E_FAIL, adjHr = E_FAIL, outHr = E_FAIL, tempHr = E_FAIL;
    if (gCardClock.attrs) {
        hasHr = gCardClock.attrs->GetFlag(BMDDeckLinkHasReferenceInput, &hasRef);
        canHr = gCardClock.attrs->GetFlag(BMDDeckLinkSupportsClockTimingAdjustment, &canAdjust);
    }
    if (gCardClock.status) {
        lockHr = gCardClock.status->GetFlag(bmdDeckLinkStatusReferenceSignalLocked, &refLocked);
        modeHr = gCardClock.status->GetInt(bmdDeckLinkStatusReferenceSignalMode, &refMode);
        flagsHr = gCardClock.status->GetInt(bmdDeckLinkStatusReferenceSignalFlags, &refFlags);
        inHr = gCardClock.status->GetFlag(bmdDeckLinkStatusVideoInputSignalLocked, &inLocked);
    }
    if (gCardClock.config) {
        adjHr = gCardClock.config->GetInt(bmdDeckLinkConfigClockTimingAdjustment, &adjust);
        outHr = gCardClock.config->GetInt(bmdDeckLinkConfigReferenceOutputMode, &refOut);
    }
    if (gCardClock.stats) tempHr = gCardClock.stats->GetInt(bmdDeckLinkStatisticDeviceTemperature, &temp);
    fprintf(stdout, "[CARDCLOCK-REF] %s host %.6f refStatus 0x%x (hr 0x%08X) hasRefInput %d (hr 0x%08X) refLocked %d (hr 0x%08X) "
                    "refMode 0x%llx (hr 0x%08X) refFlags 0x%llx (hr 0x%08X) inputLocked %d (hr 0x%08X) "
                    "supportsClockAdjust %d (hr 0x%08X) clockAdjust %lld (hr 0x%08X) refOutputMode 0x%llx (hr 0x%08X) temp %lld (hr 0x%08X)\n",
            when, cardClockHostNow(), (unsigned)ref, (unsigned)refHr, (int)hasRef, (unsigned)hasHr, (int)refLocked, (unsigned)lockHr,
            (unsigned long long)refMode, (unsigned)modeHr, (unsigned long long)refFlags, (unsigned)flagsHr, (int)inLocked, (unsigned)inHr,
            (int)canAdjust, (unsigned)canHr, (long long)adjust, (unsigned)adjHr, (unsigned long long)refOut, (unsigned)outHr,
            (long long)temp, (unsigned)tempHr);
    fflush(stdout);
}
}
#endif

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

@implementation DeckLinkRejectedDeviceInfo {
    NSInteger _index;
    NSString *_modelName;
    int32_t _hresult;
}

- (instancetype)initWithIndex:(NSInteger)index
                    modelName:(NSString *)modelName
                      hresult:(int32_t)hresult {
    if ((self = [super init])) {
        _index = index;
        _modelName = [modelName copy];
        _hresult = hresult;
    }
    return self;
}

- (NSInteger)index { return _index; }
- (NSString *)modelName { return _modelName; }
- (int32_t)hresult { return _hresult; }
// Unsigned cast before formatting: HRESULT is signed on macOS, and E_NOINTERFACE printed through a
// signed conversion comes out "0xFFFFFFFF80000004" on a 64-bit promotion. Testers paste these
// straight into a search box, so the spelling has to match Blackmagic's own.
- (NSString *)hresultHex { return [NSString stringWithFormat:@"0x%08X", (uint32_t)_hresult]; }

@end

@implementation DeckLinkEnumerationResult {
    NSInteger _totalCount;
    NSArray<DeckLinkDeviceInfo *> *_usable;
    NSArray<DeckLinkRejectedDeviceInfo *> *_rejected;
}

- (instancetype)initWithTotalCount:(NSInteger)totalCount
                            usable:(NSArray<DeckLinkDeviceInfo *> *)usable
                          rejected:(NSArray<DeckLinkRejectedDeviceInfo *> *)rejected {
    if ((self = [super init])) {
        _totalCount = totalCount;
        _usable = [usable copy];
        _rejected = [rejected copy];
    }
    return self;
}

- (NSInteger)totalCount { return _totalCount; }
- (NSArray<DeckLinkDeviceInfo *> *)usable { return _usable; }
- (NSArray<DeckLinkRejectedDeviceInfo *> *)rejected { return _rejected; }

@end

#pragma mark - Output result

@implementation DeckLinkOutputResult {
    BOOL _success;
    NSArray<NSString *> *_log;
    NSString *_activeModeName;
    NSString *_failedCall;
    int32_t _failureHResult;
}
- (instancetype)initWithSuccess:(BOOL)success log:(NSArray<NSString *> *)log {
    return [self initWithSuccess:success log:log activeModeName:nil];
}
// A failure that is a DeckLink call's answer: the call and its code travel with the log line.
- (instancetype)initFailureWithLog:(NSArray<NSString *> *)log call:(NSString *)call hresult:(HRESULT)hr {
    if ((self = [self initWithSuccess:NO log:log activeModeName:nil])) {
        _failedCall = [call copy];
        _failureHResult = (int32_t)hr;
    }
    return self;
}
- (instancetype)initWithSuccess:(BOOL)success
                            log:(NSArray<NSString *> *)log
                 activeModeName:(NSString *)activeModeName {
    if ((self = [super init])) {
        _success = success;
        _log = [log copy];
        _activeModeName = [activeModeName copy];
    }
    return self;
}
- (BOOL)success { return _success; }
- (NSArray<NSString *> *)log { return _log; }
- (NSString *)activeModeName { return _activeModeName; }
- (NSString *)failedCall { return _failedCall; }
- (int32_t)failureHResult { return _failureHResult; }
@end

#pragma mark - Audio config (D4b-2)

@implementation DeckLinkAudioConfig {
    double _sampleRate;
    NSInteger _sourceChannelCount;
    NSInteger _deckLinkChannelCount;
    double _trimSeconds;
    DeckLinkAudioSourceTimeBlock _sourceTime;
    DeckLinkAudioSilentBlock _isSilent;
    DeckLinkAudioSilentBlock _isDestinationSilent;
    DeckLinkAudioReadBlock _read;
}
@synthesize handed = _handed;
@synthesize cardTimeline = _cardTimeline;
- (instancetype)initWithSampleRate:(double)sampleRate
                sourceChannelCount:(NSInteger)sourceChannelCount
              deckLinkChannelCount:(NSInteger)deckLinkChannelCount
                       trimSeconds:(double)trimSeconds
                        sourceTime:(DeckLinkAudioSourceTimeBlock)sourceTime
                          isSilent:(DeckLinkAudioSilentBlock)isSilent
               isDestinationSilent:(DeckLinkAudioSilentBlock)isDestinationSilent
                              read:(DeckLinkAudioReadBlock)read {
    if ((self = [super init])) {
        _sampleRate = sampleRate;
        _sourceChannelCount = sourceChannelCount;
        _deckLinkChannelCount = deckLinkChannelCount;
        _trimSeconds = trimSeconds;
        _sourceTime = [sourceTime copy];
        _isSilent = [isSilent copy];
        _isDestinationSilent = [isDestinationSilent copy];
        _read = [read copy];
    }
    return self;
}
- (double)sampleRate { return _sampleRate; }
- (NSInteger)sourceChannelCount { return _sourceChannelCount; }
- (NSInteger)deckLinkChannelCount { return _deckLinkChannelCount; }
- (double)trimSeconds { return _trimSeconds; }
- (DeckLinkAudioSourceTimeBlock)sourceTime { return _sourceTime; }
- (DeckLinkAudioSilentBlock)isSilent { return _isSilent; }
- (DeckLinkAudioSilentBlock)isDestinationSilent { return _isDestinationSilent; }
- (DeckLinkAudioReadBlock)read { return _read; }
@end

// C++ mirror of the audio seam — the player is pure C++ and never sees an Obj-C block directly
// (same pattern as FrameFillFn for video). Populated from DeckLinkAudioConfig at start.
struct AudioSource {
    uint32_t sampleRate = 0;          // 48000 — the ONLY rate BMDAudioSampleRate defines
    uint32_t srcChannels = 0;         // what the ring stores (interleaved)
    uint32_t dlChannels = 0;          // SDK-legal padded count the card is enabled with (2/8/16/32/64)
    double   trimSeconds = 0.0;       // residual-latency knob (see DeckLinkAudioConfig.trimSeconds)
    std::function<double(void)> sourceTime;                                  // pts of the frame in staging
    std::function<bool(void)> isSilent;                                      // mute / pause / shuttle gate, or destination
    std::function<bool(void)> isDestinationSilent;                           // the log's label: destination is Computer
    std::function<int32_t(double, int32_t, int32_t *)> read;                 // ring read (D4b-1)
    std::function<void(double *, bool *, bool *, uint64_t *, double *, double *)> handed;   // Stage 1c: the handed frame per fill (§10.22, §10.23)
    bool cardTimeline = false;                                               // Stage 1c: the card is the file's clock (1b on)
};

#pragma mark - D3 scheduled player (synthetic, pluggable fill source)

// Pluggable frame-fill: given a frame index + a target v210 buffer, fill it. Knows NOTHING about
// DeckLink — the scheduling loop calls it blind. This is the seam where the synthetic hue-walk is
// later swapped for the Metal/decoded-frame path WITHOUT touching the scheduler. Dimensions/rowBytes
// come from the output mode (passed in), not hardcoded.
// Colour S7: returns true when it wrote a picture, and then `signal` holds that picture's signal (D1); false is a
// neutral fill, and the frame keeps the signal in force (D5).
typedef std::function<bool(int64_t frameIndex, uint8_t *buffer, int32_t rowBytes, int32_t width, int32_t height,
                           DeckLinkOutputSignal *signal)> FrameFillFn;

// Field by field: the struct comes from Swift, and its padding bytes are not part of the signal.
static bool SameSignal(const DeckLinkOutputSignal &a, const DeckLinkOutputSignal &b) {
    return (a.rec2020 != NO) == (b.rec2020 != NO) && a.eotf == b.eotf
        && (a.hasStaticMetadata != NO) == (b.hasStaticMetadata != NO)
        && (!a.hasStaticMetadata
            || (a.redX == b.redX && a.redY == b.redY && a.greenX == b.greenX && a.greenY == b.greenY
                && a.blueX == b.blueX && a.blueY == b.blueY && a.whiteX == b.whiteX && a.whiteY == b.whiteY
                && a.maxMasteringLuminance == b.maxMasteringLuminance && a.minMasteringLuminance == b.minMasteringLuminance
                && a.maxCLL == b.maxCLL && a.maxFALL == b.maxFALL));
}

// What the final frame of an ended output is tagged with: Rec.709, EOTF 0, HDR flag clear (Robbie, 2026-10-25).
static const DeckLinkOutputSignal kSDR709Signal = { NO, 0, NO };

// Video black in v210, the output's only range (10-bit Y 64, Cb = Cr = 512): the same words as the service's neutral
// fill (`DeckLinkService.fillNeutralV210`), across the whole of rowBytes.
static void FillVideoBlackV210(uint8_t *buffer, int32_t rowBytes, int32_t height) {
    const uint32_t w0 = 0x20010200, w1 = 0x04080040;   // Cb|Y|Cr = 512|64|512, Y|Cb|Y = 64|512|64
    for (int32_t y = 0; y < height; y++) {
        uint32_t *p = (uint32_t *)(buffer + (size_t)y * rowBytes);
        for (int32_t g = 0; g < rowBytes / 16; g++, p += 4) { p[0] = w0; p[1] = w1; p[2] = w0; p[3] = w1; }
    }
}

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

#pragma mark - D4b-2 audio tuning constants

// How much audio we keep queued ON THE CARD. 200 ms is deep enough to ride out a host hiccup (the
// ~50 Hz callback missing several turns, a decode stall) yet shallow enough that a transport change
// reaches the wire in ~1/5 s. It also lands close to the VIDEO queue depth (a 4-frame pool at 24p is
// ~208 ms), which is why the residual A/V trim starts at zero — the two pipelines are already about
// the same depth by construction.
static const double kAudioTargetDepthSeconds = 0.200;

// Ceiling on frames scheduled in ONE callback (0.25 s). Sizes the preallocated scratch buffers and
// bounds the work done on the card's callback thread. A normal callback schedules ~1/50 s ≈ 960 f.
static const double kAudioMaxCallbackSeconds = 0.250;

// The floor at which protecting the CARD outranks protecting the CONTENT. Above it, a ring that can't
// yet supply everything we asked for is answered with a SHORT schedule (the deep buffer absorbs it and
// the next callback collects the rest — no hole is baked into audio that had merely not decoded yet).
// Below it, the card is about to run dry, so the tail is padded with silence instead: a hardware
// underrun repeats or clicks, which is worse than a gap we can hear coming and log.
static const double kAudioCriticalDepthSeconds = 0.050;

// Drift correction band (host clock vs card clock). The source cursor advances with the frames we
// SCHEDULE (card-paced); the video's source time on the wire advances with the HOST's synchronizer
// clock. Those two clocks differ by ppm, so the alignment error is a slow ramp. We low-pass it (the
// anchor is quantized to the source frame grid, so the raw error is a ±½-frame staircase) and correct
// by skipping/duplicating at most kAudioMaxCorrectionFrames source frames per callback:
//   2 f/callback × 50 Hz ≈ 100 f/s ≈ 2 ms/s of authority — ~40× the ~50 ppm the clocks actually drift,
//   and each individual correction is a 20–40 µs skip/repeat (inaudible).
// If the SMOOTHED error still exceeds kAudioResyncSeconds, the anchor is genuinely wrong (a stall, a
// pipeline-depth change) and we snap rather than crawl — logged distinctly.
static const double kAudioErrorEmaAlpha = 0.02;      // ~1 s time constant at a 50 Hz callback
static const int32_t kAudioMaxCorrectionFrames = 2;
static const double kAudioResyncSeconds = 0.100;
// The anchor's frame (docs/CARD_CLOCK_FINDINGS.md §10.21): a frame handed in several consecutive slots is on the wire from the
// first, so its source time counts from that slot. That covers a source slower than the output (24p in 59.94: 2–3 slots; 15p:
// 4). A frame held longer (pause, a held picture) counts from its newest slot, as the depth term did before it.
static const int64_t kAudioMaxRepeatSlots = 3;   // newest − first, slots

// ── OUTPUT START: THE SDK'S ORDER, AND A CHECK THAT THE CARD'S SOUND STARTED WITH ITS PICTURE (CARD_CLOCK_FINDINGS.md §10.24) ──
// The manual (§2.4.2) and its samples end the audio preroll only once it is complete, start playback with no audio write in
// flight, and wait for ScheduledPlaybackHasStopped after a stop. The waits are bounded so a card that never answers cannot hang
// a start or a stop.
static const int kAudioPrerollWaitMs = 500;     // video preroll done → the audio preroll's completion, at most
static const int kStopWaitMs = 500;             // StopScheduledPlayback → ScheduledPlaybackHasStopped, at most
// At each output start the card's audio consumption point (queue end − queued) is read against its video stream time. In 199
// normal starts it sat 2–4 samples off; the faults were +386, +989 and "never consumed" (§10.23). Beyond the tolerance the audio is
// cleared and restarted; with nothing consumed 250 ms after the start, the whole output is restarted, once (§10.25).
static const int64_t kStartGapToleranceFrames = 12;   // 0.25 ms
static const int64_t kStartSettleFrames = 480;        // measure once 10 ms has played
static const int64_t kStartTimeoutFrames = 12000;     // 250 ms
static const int64_t kStartRestartLeadFrames = 960;   // a restarted stream's first sample: 20 ms past the card's position
static const int kStartMaxRestarts = 3;

#ifdef DEBUG
// Test switches for the output-start check (DEBUG builds only, read once per start; nothing persisted):
//   MANIFOLD_SDI_AUDIO_START=legacy   the start and stop as before §10.24 (no preroll wait, no start lock, no stop wait): what
//                                     shipped builds do, for measuring them.
//   MANIFOLD_SDI_AUDIO_RECOVER=0      measure and log, but do not restart the audio.
//   MANIFOLD_SDI_AUDIO_START_FAULT=stall      the start's audio is scheduled 10 s ahead, so the card consumes nothing: the
//                                             "not consuming" branch on a healthy card. Not on a recovery's own start (§10.25),
//                                             so every injected silent start can be seen recovered.
//   MANIFOLD_SDI_AUDIO_START_FAULT=gap:<n>    the first measurement reads n samples off: the "offset" branch on a healthy card.
//   MANIFOLD_SDI_AUDIO_PREROLL=video|200      the audio preroll's depth: the video preroll's frames, or 200 ms (§10.25 item 2).
static bool envIs(const char *name, const char *value) { const char *v = getenv(name); return v && strcmp(v, value) == 0; }
#endif

#ifdef DEBUG
// BRANCH TRACE burst length (dev diagnostic — see logAudioBranch). The first N callbacks print
// verbatim because the gate's answer in the first half-second IS the question being asked; after
// that the trace throttles to ~1/s like the other audio logs.
static const uint64_t kAudioBranchLogBurst = 20;
#endif

// The scheduled-playback engine + BOTH SDK output callbacks in ONE ref-counted object (the SDK
// requires an IDeckLinkVideoOutputCallback, and — D4b-2 — an IDeckLinkAudioOutputCallback for the
// pull-model audio stream; the SDK's own FilePlayback sample implements both on one object the same
// way). Owns the IDeckLinkOutput, a small reusable frame POOL, the running frame index, the pluggable
// fill fn, and the audio stream state. All output access is encapsulated here so start/stop ordering
// and cleanup live in one place.
class DeckLinkScheduledPlayer : public IDeckLinkVideoOutputCallback, public IDeckLinkAudioOutputCallback {
public:
    DeckLinkScheduledPlayer(IDeckLinkOutput *output,
                            BMDDisplayMode displayMode,
                            int32_t width, int32_t height, int32_t rowBytes,
                            BMDTimeValue frameDuration, BMDTimeScale timeScale,
                            FrameFillFn fill, DeckLinkOutputSignal initialSignal)
        : m_refCount(1), m_output(output), m_displayMode(displayMode),
          m_width(width), m_height(height), m_rowBytes(rowBytes),
          m_frameDuration(frameDuration), m_timeScale(timeScale),
          m_fill(std::move(fill)), m_running(false), m_nextIndex(0),
          m_completed(0), m_late(0), m_dropped(0), m_flushed(0),
          m_signal(initialSignal) {
        m_output->AddRef();
    }

    // --- Setup steps (called from the Obj-C bridge, each bool-returning so it can log per-step) ---

    // The whole answer, not just yes/no: an API error and a genuine "unsupported" read the same as a bool, and a
    // 1080p25 start was once refused and accepted seconds later with nothing to tell them apart (docs/BUGS.md, L4).
    struct ModeSupport { HRESULT hr; bool supported; BMDDisplayMode actual; bool ok() const { return hr == S_OK && supported; } };

    ModeSupport checkModeSupport() {
        ModeSupport r = { E_FAIL, false, bmdModeUnknown };
        r.hr = m_output->DoesSupportVideoMode(bmdVideoConnectionUnspecified, m_displayMode,
                                              bmdFormat10BitYUV, bmdNoVideoOutputConversion,
                                              bmdSupportedVideoModeDefault, &r.actual, &r.supported);
        return r;
    }

    // A setup step's answer: which DeckLink call it was and its HRESULT, so every failure line names both (docs/BUGS.md:
    // a refusal logged without its code cannot tell "the card is in use by another app" from anything else).
    struct CallResult { const char *call; HRESULT hr; bool ok() const { return hr == S_OK; } };

    CallResult enableOutput() {
        return { "EnableVideoOutput", m_output->EnableVideoOutput(m_displayMode, bmdVideoOutputFlagDefault) };
    }

    CallResult createPool(int poolSize) {
        for (int i = 0; i < poolSize; i++) {
            IDeckLinkMutableVideoFrame *f = NULL;
            const HRESULT hr = m_output->CreateVideoFrame(m_width, m_height, m_rowBytes, bmdFormat10BitYUV,
                                                          bmdFrameFlagDefault, &f);
            if (hr != S_OK) return { "CreateVideoFrame", hr };
            if (f == NULL) return { "CreateVideoFrame", E_POINTER };   // S_OK with no frame: logged as E_POINTER
            m_pool.push_back(f);
        }
        return { "CreateVideoFrame", S_OK };
    }

    // Register self as the completion callback + arm the running flag.
    void beginRunning() {
        m_running = true;
        m_output->SetScheduledFrameCompletionCallback(this);
    }

    // Pre-roll: fill + schedule one frame per pool slot (indices 0..pool-1).
    CallResult preroll() {
        for (size_t i = 0; i < m_pool.size(); i++) {
            const int64_t idx = m_nextIndex.fetch_add(1);
            const CallResult filled = fillFrame(m_pool[i], idx);
            if (!filled.ok()) return filled;
            tagFrame(m_pool[i], idx, m_signal);   // the signal this frame's picture was rendered under (colour S7, D1)
            const HRESULT hr = m_output->ScheduleVideoFrame(m_pool[i], idx * m_frameDuration, m_frameDuration, m_timeScale);
            if (hr != S_OK) return { "ScheduleVideoFrame", hr };
        }
        return { "ScheduleVideoFrame", S_OK };
    }

    // StartScheduledPlayback with no RenderAudioSamples in flight (§10.24): the callback skips while this holds the lock, and the
    // start waits for one already running. The SDK's SignalGenerator starts from inside its audio callback, which serialises the
    // two the same way. Legacy (DEBUG switch): as before, unserialised.
    CallResult startPlayback() {
        std::unique_lock<std::recursive_mutex> g(m_audioCbMutex, std::defer_lock);
        if (!m_legacyStart) g.lock();
        const HRESULT hr = m_output->StartScheduledPlayback(0, m_timeScale, 1.0);
        if (hr == S_OK) {
            if (m_audioEnabled) {   // the start check (§10.24), armed before the callbacks can see the stream as started
                m_sc = StartCheck(); m_sc.active = true; m_sc.origin = m_audioOrigin; m_sc.expect = 0;
            }
            m_playbackStarted = true;   // Stage 1c: edges flush, and a flush needs a running stream
        }
        return { "StartScheduledPlayback", hr };
    }

    // The audio preroll's end (§10.24). The manual: "When audio preroll is complete, call EndAudioPreroll", then start. The callback
    // ends it itself once the queue reaches its depth; this waits for that (bounded), and ends it here only if it never came.
    struct PrerollResult { double waitedMs; bool byCallback; uint32_t buffered; uint64_t callbacks; };
    PrerollResult finishAudioPreroll() {
        using Clock = std::chrono::steady_clock;
        const auto t0 = Clock::now();
        PrerollResult r = { 0, false, 0, 0 };
        if (!m_audioEnabled) return r;
        if (!m_legacyStart) {
            while (m_prerollingAudio.load() && Clock::now() - t0 < std::chrono::milliseconds(kAudioPrerollWaitMs)) usleep(500);
        }
        r.byCallback = !m_prerollingAudio.load();
        {
            std::unique_lock<std::recursive_mutex> g(m_audioCbMutex, std::defer_lock);
            if (!m_legacyStart) g.lock();
            endAudioPrerollIfNeeded();
        }
        r.waitedMs = std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
        m_output->GetBufferedAudioSampleFrameCount(&r.buffered);
        r.callbacks = m_audioCallbacks.load();
        return r;
    }
    bool legacyStart() const { return m_legacyStart; }

    // --- D4b-2 audio setup (ordering matters; see the start sequence in the bridge) ---

    // (a) EnableAudioOutput. 32-bit signed integer samples (what the D4b-1 ring already stores),
    // TIMESTAMPED stream type (we position samples explicitly on the playback timeline via streamTime,
    // rather than letting the card append them blind). Channel count is the SDK-legal PADDED count.
    // Preallocates the two scratch buffers so the callback never allocates.
    CallResult enableAudio(const AudioSource &src) {
        m_audio = src;
        const HRESULT hr = m_output->EnableAudioOutput((BMDAudioSampleRate)m_audio.sampleRate,
                                                       bmdAudioSampleType32bitInteger,
                                                       m_audio.dlChannels,
                                                       bmdAudioOutputStreamTimestamped);
        if (hr != S_OK) return { "EnableAudioOutput", hr };
        const size_t maxFrames = (size_t)std::lround(m_audio.sampleRate * kAudioMaxCallbackSeconds);
        m_maxCallbackFrames = (int32_t)maxFrames;
        m_srcScratch.assign(maxFrames * m_audio.srcChannels, 0);   // ring layout (source channels)
        m_outScratch.assign(maxFrames * m_audio.dlChannels, 0);    // wire layout (padded channels)
        if (m_audio.handed) {   // Stage 1c: what was scheduled where, and the run's sound read ahead of the queue
            m_hist.assign((size_t)kHistFrames * m_audio.dlChannels, 0);
            m_pre.assign((size_t)kPreFrames * m_audio.srcChannels, 0);
            m_preKey.assign((size_t)kPreFrames, -1);
            m_preRun.assign((size_t)kPreFrames, 0);
        }
#ifdef DEBUG
        m_legacyStart = envIs("MANIFOLD_SDI_AUDIO_START", "legacy");
        m_recoverStart = !envIs("MANIFOLD_SDI_AUDIO_RECOVER", "0");
        if (envIs("MANIFOLD_SDI_AUDIO_PREROLL", "video")) m_prerollVideoOnly = true;
        if (envIs("MANIFOLD_SDI_AUDIO_PREROLL", "200")) m_prerollVideoOnly = false;
        if (envIs("MANIFOLD_SDI_AUDIO_START_FAULT", "stall") && !m_outputRestart) {   // the preroll lands 10 s ahead: nothing is consumed
            m_audioStreamFrames = m_audioOrigin = 10 * (int64_t)m_audio.sampleRate;
        }
        if (const char *f = getenv("MANIFOLD_SDI_AUDIO_START_FAULT"); f && strncmp(f, "gap:", 4) == 0 && !m_outputRestart) m_faultGap = atoll(f + 4);
        if (m_legacyStart || !m_recoverStart || m_audioOrigin || m_faultGap || getenv("MANIFOLD_SDI_AUDIO_PREROLL"))
            fprintf(stdout, "[SDI-AUDIO] test switches: start %s, recovery %s, fault %s, preroll %s\n", m_legacyStart ? "LEGACY" : "as the SDK",
                    m_recoverStart ? "on" : "OFF (measure only)", m_audioOrigin || m_faultGap ? getenv("MANIFOLD_SDI_AUDIO_START_FAULT") : "none",
                    m_prerollVideoOnly ? "the video preroll's frames" : "200 ms");
#endif
        m_audioEnabled = true;
        return { "EnableAudioOutput", S_OK };
    }

    // (b)+(c) Register the pull callback and open the preroll window. The card starts calling
    // RenderAudioSamples(preroll=true) immediately, so the audio buffer prefills WHILE the video
    // preroll frames are being scheduled. Must be called after enableAudio(), before preroll().
    void beginAudioPreroll() {
        if (!m_audioEnabled) return;
        // §10.25 item 2: the preroll's depth. 200 ms (the steady depth) as before, or only the audio that covers the video frames the
        // preroll schedules (the manual: "sufficient for the video frames scheduled"): the pool's frames, 3,203 samples at 59.94.
        const double prerollVideoSeconds = (double)m_pool.size() * (double)m_frameDuration / (double)m_timeScale;
        m_prerollTargetFrames = (int32_t)std::lround((double)m_audio.sampleRate
                                                     * (m_prerollVideoOnly ? prerollVideoSeconds : kAudioTargetDepthSeconds));
        m_prerollingAudio = true;
        m_output->SetAudioCallback(this);
        m_output->BeginAudioPreroll();
    }

    // (c, close) Close the preroll window if the callback hasn't already (it ends it itself the moment
    // the buffer reaches the target depth). Exactly-once via the atomic exchange, because the start
    // thread and the callback thread race for it by design.
    void endAudioPrerollIfNeeded() {
        if (!m_audioEnabled) return;
        bool expected = true;
        if (m_prerollingAudio.compare_exchange_strong(expected, false))
            m_output->EndAudioPreroll();
    }

    bool audioEnabled() const { return m_audioEnabled; }

    // Clean, idempotent stop. Safe even if never started, and safe against an in-flight callback (video
    // OR audio): m_running is cleared FIRST (both callbacks early-return on it, so neither reschedules
    // nor touches the output), then playback is stopped and BOTH callbacks are unset (the SDK stops
    // invoking us) BEFORE the pool/output are released. Audio teardown mirrors setup in reverse.
    //
    // `endOnBlack`: the output is ending, not re-establishing (Robbie, 2026-10-25). Before the output is disabled, one
    // frame of video black tagged Rec.709 SDR is shown and held, so the card holds black whatever its idle setting and
    // the last signalling it saw is SDR. The frame is filled before playback stops, to keep the gap short; it is
    // tagged after the callback is unset, when nothing else touches the signal log.
    void stop(bool endOnBlack = false) {
        m_running = false;
        if (m_output) {
            using Clock = std::chrono::steady_clock;
            const auto t0 = Clock::now();
            IDeckLinkMutableVideoFrame *black = endOnBlack ? makeBlackFrame() : NULL;
            BMDTimeValue actualStop = 0;
            m_stoppedSignal = false;
            const HRESULT stopHr = m_output->StopScheduledPlayback(0, &actualStop, m_timeScale);
            // §10.24: the SDK's FilePlayback waits for ScheduledPlaybackHasStopped before going on; until 2026-11-11 this unset the
            // callback at once, so it never came (0 in 200 restarts) and the next start could follow a stop the driver had not
            // finished. Bounded, logged.
            if (!m_legacyStart && stopHr == S_OK && m_playbackStarted.load()) {
                const auto w0 = Clock::now();
                while (!m_stoppedSignal.load() && Clock::now() - w0 < std::chrono::milliseconds(kStopWaitMs)) usleep(500);
                const double ms = std::chrono::duration<double, std::milli>(Clock::now() - w0).count();
                fprintf(stdout, "DeckLink D3: stop — %s %.1f ms after StopScheduledPlayback\n",
                        m_stoppedSignal.load() ? "ScheduledPlaybackHasStopped" : "⚠️ no ScheduledPlaybackHasStopped in", ms);
                fflush(stdout);
            }
            m_output->SetScheduledFrameCompletionCallback(NULL);
            if (m_audioEnabled) {
                m_prerollingAudio = false;
                m_output->SetAudioCallback(NULL);
                m_output->FlushBufferedAudioSamples();   // drop anything still queued
                m_output->DisableAudioOutput();
                m_audioEnabled = false;
            }
            if (endOnBlack) {
                if (black) showFinalBlack(black, t0);
                else { fprintf(stdout, "DeckLink: ⚠️ final black frame not shown — the frame could not be made\n"); fflush(stdout); }
            }
            m_output->DisableVideoOutput();
        }
        for (auto *f : m_pool) { if (f) f->Release(); }
        m_pool.clear();
        if (m_output) { m_output->Release(); m_output = NULL; }
    }

    // Stage 1c (§10.22): one slot as the fill saw it, and one run of a file's sound on the card's timeline.
    // `due` (timed pulls only) and `srcFrame`: the picture's line and the source's frame, for a rate mismatch (C6, §10.23).
    struct Slot { int64_t idx = -1; double pts = NAN; bool timed = false, handed = false; double due = NAN, srcFrame = 0; };
    // A run at a rate mismatch (`cad`) also carries the picture's line: frame pts0 + k × fs is first shown at the first slot i whose
    // due time phi + i × card frame reaches it. `confirmed`: the frame grid (pts0) checked against the next frame that moved.
    // C6 follow-up (§10.24, item 2): [lo, hi) bounds phi from the frames actually shown. A frame first shown at slot i was due there
    // (phi ≥ pts − i × card frame) and, when slot i − 1 showed the frame before, not due there (phi < pts − (i − 1) × card frame).
    // `above`: first showings since the last re-derive that put phi at or past hi (a frame shown a slot later than the line says).
    // A matched-rate run (§10.25 item 4) latches on the first slot that moved, provisionally (`confirmed` false): its line is that slot
    // (`lineIdx`, `pts0`) until the next timed slot confirms it, moves the start to a held first frame's last showing, or corrects D.
    // `tries`: such corrections so far.
    struct Run { bool valid = false; int64_t start = 0, end = INT64_MAX, D = 0; uint64_t serial = 0;
                 bool cad = false, confirmed = true; double phi = 0, pts0 = 0, fs = 0; int64_t lineIdx = -1;
                 double lo = -INFINITY, hi = INFINITY; int above = 0; int tries = 0; };
    void logRunsSummary() const {
        if (!m_audio.handed) return;
        fprintf(stdout, "[SDI-AUDIO] stopped — latches %llu, run ends %llu (%llu off the line on a timed pull), re-latches %llu, late edges %llu (%lld samples), edges on a deep queue %llu, "
                        "missing %lld samples (%lld filled in later), audio callbacks %llu, rate-mismatch runs %llu (grid fixed at confirm %llu, frames shown before their sound %llu, worst %.1f samples), "
                        "seek starts found by the fine search %llu (%lld samples recovered), lines re-derived from first showings %llu, "
                        "edges appended by the card %llu, provisional latches moved to a held first frame %llu, re-derived from the next frame %llu, %s\n",
                (unsigned long long)m_latches, (unsigned long long)m_runEnds, (unsigned long long)m_timedEnds, (unsigned long long)m_relatches,
                (unsigned long long)m_lateEdges, (long long)m_lateEdgeFrames, (unsigned long long)m_deepEdges, (long long)m_runMissingFrames, (long long)m_filledLate,
                (unsigned long long)m_audioCallbacks.load(), (unsigned long long)m_cadRuns, (unsigned long long)m_cadGridFixes, (unsigned long long)m_envMisses,
                m_envWorst, (unsigned long long)m_fineStarts, (long long)m_fineRecovered, (unsigned long long)m_cadRederives,
                (unsigned long long)m_appendedEdges, (unsigned long long)m_provHolds, (unsigned long long)m_provRederives,
                m_audio.cardTimeline ? "card timeline (gate on)" : "gate off: no runs, the §10.21 loop");
    }

    // Stats (read after stop for the run summary).
    void setCardFrame(DeckLinkCardFrameBlock block) { m_cardFrame = block; }   // before the start, so no callback races it
    void setSilentStart(DeckLinkSilentStartBlock block, bool outputRestart) { m_silentStart = block; m_outputRestart = outputRestart; }
    int64_t  framesScheduled() const { return m_nextIndex.load(); }
    uint64_t completedCount()  const { return m_completed.load(); }
    uint64_t lateCount()       const { return m_late.load(); }
    uint64_t droppedCount()    const { return m_dropped.load(); }
    uint64_t flushedCount()    const { return m_flushed.load(); }

    // --- IUnknown ---
    HRESULT QueryInterface(REFIID iid, LPVOID *ppv) override {
        if (ppv == nullptr) return E_POINTER;
        CFUUIDBytes iunknown = CFUUIDGetUUIDBytes(IUnknownUUID);
        if (memcmp(&iid, &iunknown, sizeof(REFIID)) == 0) {
            *ppv = static_cast<IDeckLinkVideoOutputCallback *>(this); AddRef(); return S_OK;
        }
        if (memcmp(&iid, &IID_IDeckLinkVideoOutputCallback, sizeof(REFIID)) == 0) {
            *ppv = static_cast<IDeckLinkVideoOutputCallback *>(this); AddRef(); return S_OK;
        }
        if (memcmp(&iid, &IID_IDeckLinkAudioOutputCallback, sizeof(REFIID)) == 0) {
            *ppv = static_cast<IDeckLinkAudioOutputCallback *>(this); AddRef(); return S_OK;
        }
        *ppv = nullptr; return E_NOINTERFACE;
    }
    ULONG AddRef() override { return ++m_refCount; }
    ULONG Release() override { ULONG r = --m_refCount; if (r == 0) delete this; return r; }

    // --- IDeckLinkAudioOutputCallback (D4b-2) -------------------------------------------------
    //
    // Fires ~50 Hz on the SDK's audio callback thread (serially — all m_audio* state below is touched
    // ONLY here, so it needs no lock), plus during BeginAudioPreroll with preroll=true.
    //
    // The whole scheme in one line: serve the audio that belongs to the SOURCE TIMESTAMP OF THE VIDEO
    // GOING OUT THE CARD, not to the wall clock. Two independent loops do that:
    //
    //   DEPTH loop  — how MANY frames to schedule. Top the card's audio buffer back up to
    //                 kAudioTargetDepthSeconds. This alone is the host-vs-card rate match: if the card's
    //                 clock runs fast the buffer drains faster, the top-up is bigger, we schedule more.
    //                 The card's own consumption is the feedback signal, so no explicit rate estimate.
    //
    //   ANCHOR loop — WHERE in source time to read. A continuous cursor (m_cursorSeconds) advances by
    //                 exactly the frames scheduled, which is what makes the audio sample-continuous (no
    //                 gaps, no repeats, no clicks). It is steered toward the source time the video on
    //                 the wire will carry when these samples reach it:
    //
    //                   ideal = handedPts + (audioStreamTime − handedStreamTime) + trim
    //
    //                 handedPts is the source PTS of the frame the fill block last handed the card, and
    //                 handedStreamTime the stream time it was scheduled at (its slot × the frame duration);
    //                 audioStreamTime is where the samples about to be scheduled land. Both streams share
    //                 the t=0 of StartScheduledPlayback(0,…), so the difference is exact: no queue depth is
    //                 sampled and no callback phase enters (docs/CARD_CLOCK_FINDINGS.md §10.16, §10.21).
    //                 Until 2026-11-10 the term was stagedPts + (audioDepth − videoDepth), videoDepth =
    //                 (bufferedVideo + 1) frames: it counted 5 frames for a frame that is 3 − φ from the
    //                 wire, so SDI sound ran 2.5 frames late (docs/BUGS.md). What follows describes it.
    //                 audioDepth/videoDepth were the two pipelines' queue
    //                 depths — measured, not assumed — so the delta compensates the pipeline skew every
    //                 callback. Steering is a ≤2-sample skip/repeat per callback (see the constants).
    HRESULT RenderAudioSamples(bool preroll) override {
        m_audioCallbacks.fetch_add(1, std::memory_order_relaxed);
        if (!m_running.load() || !m_audioEnabled) return S_OK;
        // §10.24: never inside StartScheduledPlayback or the preroll's end; the start holds this lock across them. Skipping one call
        // costs nothing (the queue is 80–200 ms deep), and the callback never waits on the start thread, so the two cannot deadlock.
        std::unique_lock<std::recursive_mutex> cbLock(m_audioCbMutex, std::try_to_lock);
        if (!cbLock.owns_lock()) { m_audioCbSkipped++; return S_OK; }
        if (m_playbackStarted.load() && m_sc.active) checkStart();

        uint32_t buffered = 0;
        if (m_output->GetBufferedAudioSampleFrameCount(&buffered) != S_OK) return E_FAIL;

        // Stage 1c (docs/CARD_CLOCK_FINDINGS.md §10.22): a file's sound on the card's own timeline, in runs, under card lock (gate on)
        // only. A live source, and a file with the gate off, keep the §10.21 anchor loop below (§10.20: gate off is today's path).
        if (m_audio.handed && m_audio.cardTimeline && m_byTime.load()) {
            if (!m_runsMode) {
                m_runsMode = true; m_runActive = false; m_run = Run(); m_prev = Run(); m_errEma = 0.0;
                fprintf(stdout, "[SDI-AUDIO] runs path entered: preroll %d, playback started %d, buffered %u, stream %lld, audio callbacks %llu\n",
                        (int)preroll, (int)m_playbackStarted.load(), buffered, (long long)m_audioStreamFrames,
                        (unsigned long long)m_audioCallbacks.load());
                fflush(stdout);
            }
            return renderRuns(preroll);
        }
        if (m_runsMode) { m_runsMode = false; m_runActive = false; m_cursorAnchored = false; }

        const double rate = (double)m_audio.sampleRate;
        const int32_t targetFrames = preroll ? m_prerollTargetFrames : (int32_t)std::lround(rate * kAudioTargetDepthSeconds);

        // At/above the target depth there is nothing to do — and if this is the preroll window, being
        // at depth is precisely the signal to CLOSE it (the SDK's FilePlayback sample ends preroll from
        // inside the callback the same way).
        if ((int32_t)buffered >= targetFrames) {
            if (preroll) endAudioPrerollIfNeeded();
            return S_OK;
        }

        // DEPTH loop: top up to target, bounded by the per-callback ceiling.
        int32_t want = targetFrames - (int32_t)buffered;
        want = std::min(want, m_maxCallbackFrames);
        if (want <= 0) return S_OK;

        // The A/V gate. Pause / off-speed JKL shuttle / user mute → the stream carries SILENCE, but it
        // KEEPS FLOWING (zeros, streamTime advancing) so the card never starves. Rationale: the decode
        // pump only runs at 1×, so the ring cannot supply audio at 4× or in reverse — real scrub audio
        // needs a separate DSP path (deferred). Pause is silence for a reason specific to this PULL
        // model: the source time is frozen, so re-serving the same window at 50 Hz would drone. The
        // system renderer gets pause-silence for free (its clock simply stops pulling).
        const bool silent = m_audio.isSilent ? m_audio.isSilent() : true;
        if (silent) {
            m_cursorAnchored = false;   // re-anchor to the video on the next unmuted callback
            m_errEma = 0.0;
            const bool toComputer = m_audio.isDestinationSilent && m_audio.isDestinationSilent();
            logAudioBranch(toComputer ? "SILENCE · audio destination is Computer"
                                      : "SILENCE · transport gate (isCardAudioSilent: muted or shuttleRate != 1)",
                           silent, -1, want);
            return scheduleSilence(want) ? S_OK : E_FAIL;
        }

        // The anchor: source PTS of the frame in the DeckLink staging buffer. NaN → no converted frame
        // yet (output just started / no file) → nothing to align to, so hold silence.
        const double stagedPts = m_audio.sourceTime ? m_audio.sourceTime() : NAN;
        if (!std::isfinite(stagedPts)) {
            m_cursorAnchored = false;
            logAudioBranch("SILENCE · no staged video PTS to anchor to", silent, -1, want);
            return scheduleSilence(want) ? S_OK : E_FAIL;
        }

        // The handed frame and its slot (docs/CARD_CLOCK_FINDINGS.md §10.21). The samples scheduled now land at
        // stream time m_audioStreamFrames / rate; the handed frame went out at handedIdx × frame. The source time
        // of those samples is the frame's pts plus the difference. This replaced a queue-depth estimate that
        // counted the handed frame 2 + φ frames too far from the wire (docs/BUGS.md, "SDI audio lags its
        // picture by 2.5 frames").
        double handedPts = NAN;
        int64_t handedIdx = -1;
        if (!handedFrame(handedPts, handedIdx)) {
            m_cursorAnchored = false;
            logAudioBranch("SILENCE · no handed frame to anchor to", silent, -1, want);
            return scheduleSilence(want) ? S_OK : E_FAIL;
        }
        uint32_t bufferedVideo = 0;   // the periodic log's vq= only
        m_output->GetBufferedVideoFrameCount(&bufferedVideo);
        const double audioStreamTime = (double)m_audioStreamFrames / rate;
        const double handedStreamTime = (double)handedIdx * (double)m_frameDuration / (double)m_timeScale;
        const double ideal = handedPts + (audioStreamTime - handedStreamTime) + m_audio.trimSeconds;

        int32_t correction = 0;
        char corrKind = 'c';   // [AUDIO-CORR] only
        if (!m_cursorAnchored) {
            corrKind = 'a';
            m_cursorSeconds = ideal;    // fresh start / post-seek / unmute: snap, don't crawl
            m_errEma = 0.0;
            m_cursorAnchored = true;
        } else {
            // ANCHOR loop. The raw error is a ±½-source-frame staircase (stagedPts is quantized to the
            // source frame grid, bufferedVideo to whole frames), so steer off the SMOOTHED error only.
            const double err = ideal - m_cursorSeconds;
            m_errEma += kAudioErrorEmaAlpha * (err - m_errEma);
            if (std::fabs(m_errEma) > kAudioResyncSeconds) {
                m_resyncs++;
                corrKind = 'r';
                fprintf(stdout, "DeckLinkAudio: !! RESYNC — smoothed error %+.1f ms exceeds %.0f ms; "
                                "snapping source cursor %.3fs → %.3fs\n",
                        m_errEma * 1000.0, kAudioResyncSeconds * 1000.0, m_cursorSeconds, ideal);
                fflush(stdout);
                m_cursorSeconds = ideal;
                m_errEma = 0.0;
            } else {
                // Skip (+) or repeat (−) at most kAudioMaxCorrectionFrames source frames, chasing 10% of
                // the smoothed residual per callback. A 2-frame step at 48 kHz is ~42 µs — below any
                // audible threshold — and the authority (≈2 ms/s) outruns real clock drift by ~40×.
                // Sub-5-sample residuals round to zero, so a settled loop applies no correction at all.
                const double demand = m_errEma * rate * 0.10;
                correction = (int32_t)std::lround(std::max((double)-kAudioMaxCorrectionFrames,
                                                  std::min((double)kAudioMaxCorrectionFrames, demand)));
                m_cursorSeconds += (double)correction / rate;
            }
        }

        // Read the ring at the cursor. `got` < `want` means the DECODER hasn't reached that far yet —
        // schedule only what actually exists rather than padding the tail with silence, which would bake
        // a permanent hole into the stream (the missing audio would be skipped over for good). The card
        // has ~200 ms queued, so a short schedule is free; the next callback picks up the rest.
        int32_t *src = m_srcScratch.data();
        const int32_t got = m_audio.read ? m_audio.read(m_cursorSeconds, want, src) : 0;

        if (got <= 0) {
            // Nothing at this source time at all: post-seek gap (the ring was reset), or the source has
            // no audio. Fill silence and drop the anchor so the next callback with data re-syncs cleanly.
            m_underruns++;
            noteUnderrunCallback(want);
            m_cursorAnchored = false;
            m_errEma = 0.0;
            logAudioBranch("SILENCE · ring empty at the cursor (underrun)", silent, 0, want);
            logUnderrunThrottled(m_cursorSeconds, want);
            return scheduleSilence(want) ? S_OK : E_FAIL;
        }
        // Past every silence return: this callback is serving REAL audio out of the ring.
        endUnderrunEventIfAny();
        logAudioBranch("PCM · read from the ring", silent, got, want);
        // The ring had SOME but not all of what we asked for — the decoder simply hasn't reached that far
        // yet. Schedule only what exists (see kAudioCriticalDepthSeconds) unless the card is about to run
        // dry, in which case pad the tail with silence to keep the hardware fed.
        int32_t toSchedule = got;
        int32_t silencePad = 0;
        if (got < want) {
            m_shortReads++;
            const int32_t criticalFrames = (int32_t)std::lround(rate * kAudioCriticalDepthSeconds);
            if ((int32_t)buffered < criticalFrames) {
                silencePad = want - got;
                toSchedule = want;
            }
        }

        // CHANNEL PADDING (at schedule time — the ring stores SOURCE channels only). Interleave the source
        // channels into the SDK-legal count (2/8/16/32/64); the extra channels carry digital silence.
        const uint32_t sc = m_audio.srcChannels, dc = m_audio.dlChannels;
        int32_t *dst = m_outScratch.data();
        if (sc == dc && silencePad == 0) {
            memcpy(dst, src, (size_t)got * sc * sizeof(int32_t));
        } else {
            memset(dst, 0, (size_t)toSchedule * dc * sizeof(int32_t));   // extra channels + any tail pad
            for (int32_t f = 0; f < got; f++) {
                const int32_t *s = src + (size_t)f * sc;
                int32_t *d = dst + (size_t)f * dc;
                for (uint32_t c = 0; c < sc; c++) d[c] = s[c];
            }
        }

        const BMDTimeValue streamBefore = m_audioStreamFrames;   // [AUDIO-CORR] only
        const uint32_t written = scheduleFrames(dst, toSchedule);
#ifdef DEBUG
        if (kAudioCorrLog)
            fprintf(stdout, "[AUDIO-CORR] s=%lld n=%u got=%d c=%d k=%c e=%+.3f cur=%.6f\n", (long long)streamBefore, written, got,
                    correction, corrKind, m_errEma * 1000.0, m_cursorSeconds);
#else
        (void)streamBefore; (void)corrKind;
#endif
        // Split what the card accepted into REAL and SILENCE for the stopped-summary breakdown: the
        // buffer is `got` ring frames followed by `silencePad` zeros, so a short accept takes from the
        // tail first. Without this split the summary's total is indistinguishable from pure silence.
        const uint32_t writtenReal = std::min(written, (uint32_t)got);
        m_pcmFramesScheduled     += writtenReal;
        m_silenceFramesScheduled += written - writtenReal;
        // Sample-continuous: the cursor advances ONLY over REAL frames that the card actually accepted.
        // Silence padding is deliberately NOT counted as source time consumed — the source audio it stood
        // in for is not skipped, it is simply late, and the anchor loop (or a resync) reconciles that.
        m_cursorSeconds += (double)std::min((int32_t)written, got) / rate;
        logPeriodic(buffered, bufferedVideo, written, got, want, correction, silencePad);
        return S_OK;
    }

    // --- IDeckLinkVideoOutputCallback (runs on the SDK's dedicated callback thread) ---
    HRESULT ScheduledFrameCompleted(IDeckLinkVideoFrame *completedFrame, BMDOutputFrameCompletionResult result) override {
        // The card's line, for the file clock (docs/CARD_CLOCK_FINDINGS.md §10.1). Only a frame that completed has a stamp that
        // says when its slot passed; a late or dropped frame still counts as a slot, so the line stays true across it.
        if (m_cardFrame && result == bmdOutputFrameCompleted) {
            BMDTimeValue stamp = 0;
            if (m_output->GetFrameCompletionReferenceTimestamp(completedFrame, 1000000000, &stamp) == S_OK)
                m_cardFrame((int64_t)(m_completed.load() + m_late.load() + m_dropped.load()), (double)stamp / 1e9);
        }
#if DEBUG
        // [CADENCE] the first completions against the card's clock: which result, the stream time now, and the
        // frame's own completion timestamp, so a frame-#0 drop at start can be placed (docs/BUGS.md).
        if (getenv("MANIFOLD_DECKLINK_CADENCE_LOG") && m_completed.load() + m_dropped.load() + m_late.load() < 8) {
            BMDTimeValue streamTime = 0; double speed = 0; BMDTimeValue doneTime = 0;
            m_output->GetScheduledStreamTime(m_timeScale, &streamTime, &speed);
            m_output->GetFrameCompletionReferenceTimestamp(completedFrame, m_timeScale, &doneTime);
            fprintf(stdout, "[CADENCE] completion result %d stream %lld done %lld (timescale %lld, frame %lld)\n",
                    (int)result, (long long)streamTime, (long long)doneTime, (long long)m_timeScale,
                    (long long)m_frameDuration);
            fflush(stdout);
        }
#endif
#if DEBUG
        if (kCardClockLog && result != bmdOutputFrameFlushed) {
            const uint64_t n = m_completed.load() + m_late.load() + m_dropped.load();
            const uint64_t perSecond = (uint64_t)std::llround((double)m_timeScale / (double)m_frameDuration);
            if (perSecond && n % perSecond == 0) {
                BMDTimeValue done = 0, hw = 0, inFrame = 0, ticks = 0;
                const double before = cardClockHostNow();
                m_output->GetHardwareReferenceClock(1000000000, &hw, &inFrame, &ticks);
                const double after = cardClockHostNow();
                m_output->GetFrameCompletionReferenceTimestamp(completedFrame, 1000000000, &done);
                fprintf(stdout, "[CARDCLOCK] n %llu result %d host %.9f hostAfter %.9f done %lld hw %lld inFrame %lld ticks %lld\n",
                        (unsigned long long)n, (int)result, before, after, (long long)done, (long long)hw, (long long)inFrame, (long long)ticks);
                fflush(stdout);
                if (n % (perSecond * 60) == 0) cardClockLogReference("minute", m_output);
            }
        }
#endif
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
        tagFrame(frame, idx, m_signal);   // the signal this frame's picture was rendered under (colour S7, D1)
        m_output->ScheduleVideoFrame(frame, idx * m_frameDuration, m_frameDuration, m_timeScale);

        // Diagnostic (§10.22, verification): the audio callback must keep coming while the output runs.
        if (m_audioEnabled && (idx % 48) == 0) {
            const uint64_t ac = m_audioCallbacks.load(std::memory_order_relaxed);
            if (ac == m_audioCallbacksSeen) {
                uint32_t ab = 0; m_output->GetBufferedAudioSampleFrameCount(&ab);
                fprintf(stdout, "[SDI-AUDIO] !! no audio callback in the last 48 frames (frame %lld): callbacks %llu, audio buffered %u, queue end %lld\n",
                        (long long)idx, (unsigned long long)ac, ab, (long long)m_audioStreamFrames);
                fflush(stdout);
            }
            m_audioCallbacksSeen = ac;
        }

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
        m_stoppedSignal = true;   // stop() waits for this (§10.24); it logs the wait
        return S_OK;
    }

private:
    ~DeckLinkScheduledPlayer() { }   // deleted via Release(); output/pool already freed by stop()

    // --- D4b-2 audio helpers (audio callback thread only) ---

    // The ONE schedule call. `sampleFramesWritten` MUST be non-NULL: passing NULL makes
    // ScheduleAudioSamples BLOCK until the card can accept every frame — fatal on a callback thread.
    // With it, the call returns immediately and reports a short write, which we honor (the cursor and
    // the stream time both advance by what was actually accepted, never by what we asked for).
    //
    // streamTime/timeScale: the audio stream is timestamped in its OWN sample-rate timescale, so
    // streamTime is exactly the cumulative count of scheduled sample frames — an integer, no rounding
    // against the video's timescale. Both streams share the t=0 origin set by StartScheduledPlayback(0,…),
    // so audio frame S and video stream time S/sampleRate land on the wire together.
    uint32_t scheduleFrames(int32_t *buffer, int32_t frameCount) {
        if (frameCount <= 0) return 0;
        uint32_t written = 0;
        const HRESULT hr = m_output->ScheduleAudioSamples(buffer, (uint32_t)frameCount,
                                                          m_audioStreamFrames,
                                                          (BMDTimeScale)m_audio.sampleRate,
                                                          &written);   // non-NULL → never blocks
        if (hr != S_OK) return 0;
        m_audioStreamFrames += (BMDTimeValue)written;
        if (written < (uint32_t)frameCount) m_shortSchedules++;
        return written;
    }

    // Digital silence for `frames` — the card keeps receiving a continuous stream (muted, paused,
    // shuttling, or waiting for the ring), never a starved one. The out scratch is zeroed in place;
    // it is fully rewritten by the PCM path, so no state leaks between the two.
    bool scheduleSilence(int32_t frames) {
        frames = std::min(frames, m_maxCallbackFrames);
        if (frames <= 0) return true;
        memset(m_outScratch.data(), 0, (size_t)frames * m_audio.dlChannels * sizeof(int32_t));
        m_silenceFramesScheduled += scheduleFrames(m_outScratch.data(), frames);
        return true;
    }

    // ----- Output start: did the card's sound start with its picture? (docs/CARD_CLOCK_FINDINGS.md §10.24) -----
    // The card's audio consumption point is the queue's end less what it still holds; against the video's stream time it reads 2–4
    // samples in a normal start. At 59.94 the card sometimes never consumed its preroll (5 of 100 restarts: no SDI sound for the
    // whole session), or started its sound 386 or 989 samples off its picture for the session (§10.23). Both paths (a file's runs
    // and the anchor loop) and every source are checked, once per output start: the gap measured once 10 ms has played, and
    // "consuming" by 250 ms. A start off its picture clears the card's audio and restarts the stream 20 ms ahead, up to
    // kStartMaxRestarts times, one line each. A start that consumes nothing goes to `silentStart`: the service restarts the whole
    // output (§10.25). Audio callback only (`m_sc` is armed by the start before the stream is marked started).
    struct StartCheck { bool active = false; int restarts = 0; int64_t origin = 0, expect = 0; };
    void checkStart() {
        const BMDTimeScale rate = (BMDTimeScale)m_audio.sampleRate;
        BMDTimeValue n1 = 0, n2 = 0; double sp = 0; uint32_t q = 0;
        m_output->GetScheduledStreamTime(rate, &n1, &sp);
        m_output->GetBufferedAudioSampleFrameCount(&q);
        m_output->GetScheduledStreamTime(rate, &n2, &sp);
        if (n2 - n1 > 8) return;   // preempted between the reads: the next callback measures
        const int64_t now = (int64_t)(n1 + n2) / 2;
        if (now < m_sc.expect + kStartSettleFrames) return;
        const int64_t point = (int64_t)m_audioStreamFrames - (int64_t)q;
        const int64_t consumed = point - m_sc.origin;
        int64_t gap = point - now;
#ifdef DEBUG
        if (m_faultGap && m_sc.restarts == 0) gap += m_faultGap;
#endif
        if (consumed > 0 && std::llabs(gap) <= kStartGapToleranceFrames) {
            m_sc.active = false;
            fprintf(stdout, "[SDI-AUDIO] output start: the card's sound started with its picture, %+lld samples%s%s; %llu audio callbacks "
                            "skipped during the start\n", (long long)gap,
                    m_sc.restarts ? (m_sc.restarts == 1 ? " (after 1 restart)" : " (after restarts)") : "",
                    m_outputRestart ? " (the silent-start recovery's output restart)" : "",
                    (unsigned long long)m_audioCbSkipped);
            fflush(stdout);
        } else if (consumed > 0) {
            restartStartAudio("started off its picture", gap, now, q);
        } else if (now >= m_sc.expect + kStartTimeoutFrames) {
            silentStart(gap, now, q);
        }
    }

    // A silent start: nothing consumed 250 ms after the start. Flushing and rescheduling did not revive the card (§10.24: the queue
    // stayed at 5,999 through 3 restarts); only a whole output stop and start has. So the service restarts the output, at most once per
    // output start (Robbie, 2026-11-11; §10.25). The bridge measures and hands it up; the service writes the one line and counts it.
    void silentStart(int64_t gap, int64_t now, uint32_t queued) {
        m_sc.active = false;
        const bool restart = m_recoverStart && !m_outputRestart;
        char what[256];
        snprintf(what, sizeof what, "did not start: nothing consumed %lld samples after the start (consumption point %+lld samples, now %lld, "
                                    "queued %u to %lld)", (long long)(now - m_sc.expect), (long long)gap, (long long)now, queued,
                 (long long)m_audioStreamFrames);
        if (m_silentStart) { m_silentStart([NSString stringWithUTF8String:what], restart); return; }
        fprintf(stdout, "[SDI-AUDIO] !! output start: the card's sound %s; not restarted (no handler)\n", what);
        fflush(stdout);
    }

    void restartStartAudio(const char *what, int64_t gap, int64_t now, uint32_t queued) {
        const BMDTimeScale rate = (BMDTimeScale)m_audio.sampleRate;
        if (!m_recoverStart || m_sc.restarts >= kStartMaxRestarts) {
            m_sc.active = false;
            fprintf(stdout, "[SDI-AUDIO] !! output start: the card's sound %s (consumption point %+lld samples, now %lld, queued %u to %lld); %s\n",
                    what, (long long)gap, (long long)now, queued, (long long)m_audioStreamFrames,
                    m_recoverStart ? "giving up after the restarts" : "NOT restarted (measure only)");
            fflush(stdout);
            return;
        }
        m_sc.restarts++;
        const int64_t oldEnd = m_audioStreamFrames;
        m_output->FlushBufferedAudioSamples();
        uint32_t left = 0; m_output->GetBufferedAudioSampleFrameCount(&left);
        BMDTimeValue n = 0; double sp = 0; m_output->GetScheduledStreamTime(rate, &n, &sp);
        // Past anything the flush could not remove (the card keeps what it has committed, §10.22 C0).
        const int64_t origin = (int64_t)n + kStartRestartLeadFrames + (int64_t)left;
        m_audioStreamFrames = m_audioOrigin = origin;
        // What was scheduled is gone: no history to rewrite against, no run, no anchor. The next timed slot that moves latches anew.
        std::fill(m_hist.begin(), m_hist.end(), 0);
        m_runActive = false; m_run = Run(); m_prev = Run(); m_pendingFrom = -1;
        m_cursorAnchored = false; m_errEma = 0.0; m_holdSince = -1; m_holdLogged = false; m_steerErr = NAN;
        m_sc.origin = m_sc.expect = origin;
        fprintf(stdout, "[SDI-AUDIO] !! output start: the card's sound %s (consumption point %+lld samples, now %lld, queued %u to %lld); "
                        "cleared (%u left) and restarted at stream %lld, restart %d of %d\n",
                what, (long long)gap, (long long)now, queued, (long long)oldEnd, left,
                (long long)origin, m_sc.restarts, kStartMaxRestarts);
        fflush(stdout);
    }

    // Once per second of scheduled audio: the card's depth, where we are in the SOURCE, what the ring
    // could supply, and the running drift + corrections. Watching `drift` and `corr` over minutes is how
    // host-vs-card clock divergence becomes visible instead of mysterious.
    void logPeriodic(uint32_t bufferedAudio, uint32_t bufferedVideo,
                     uint32_t written, int32_t got, int32_t want, int32_t correction, int32_t silencePad) {
        if (m_audioStreamFrames - m_lastAudioLogFrames < (BMDTimeValue)m_audio.sampleRate) return;
        m_lastAudioLogFrames = m_audioStreamFrames;
        const double rate = (double)m_audio.sampleRate;
        fprintf(stdout,
                "DeckLinkAudio: buffered=%uf (%.0fms) · srcT=%.3fs · sched=%uf (want=%df ringAvail=%df"
                "%s) · vq=%uf · drift=%+.2fms · corr=%+df · underruns=%llu events=%llu short=%llu resyncs=%llu\n",
                bufferedAudio, (double)bufferedAudio / rate * 1000.0, m_cursorSeconds,
                written, want, got, silencePad > 0 ? " +PAD" : "", bufferedVideo,
                m_errEma * 1000.0, correction,
                (unsigned long long)m_underruns, (unsigned long long)m_underrunEvents,
                (unsigned long long)m_shortReads, (unsigned long long)m_resyncs);
        fflush(stdout);
    }

#ifdef DEBUG
    // BRANCH TRACE (dev diagnostic, DEBUG builds only — Debug and Profile define DEBUG=1; see
    // project.yml). It answers one question the other audio logs CANNOT:
    //
    //   Is this callback serving real PCM out of the ring, or is it serving digital silence?
    //
    // underruns / shortReads / resyncs are all counted INSIDE the real path, after the gate. The
    // gate's `if (silent)` returns before the ring is ever touched, so a run that scheduled nothing
    // but silence reports underruns=0 shortReads=0 resyncs=0 — identical to a perfectly healthy run.
    // That ambiguity is what this line removes: it names the branch and, on the real branch, the
    // frame count the ring actually supplied.
    //
    // `got` convention: -1 = the ring was never read (gate / no anchor), >= 0 = frames read.
    // First kAudioBranchLogBurst callbacks verbatim (start-up is where the gate's answer matters
    // most), then ~1/s of SCHEDULED audio, matching logPeriodic, so a long run stays readable.
    void logAudioBranch(const char *branch, bool silent, int32_t got, int32_t want) {
        const uint64_t call = ++m_branchLogCalls;
        if (call > kAudioBranchLogBurst &&
            m_audioStreamFrames - m_lastBranchLogFrames < (BMDTimeValue)m_audio.sampleRate) return;
        m_lastBranchLogFrames = m_audioStreamFrames;
        if (got < 0) {
            fprintf(stdout, "DeckLinkAudio: branch #%llu — silent=%s → %s (want=%df, ring NOT read)\n",
                    (unsigned long long)call, silent ? "true" : "false", branch, want);
        } else {
            fprintf(stdout, "DeckLinkAudio: branch #%llu — silent=%s → %s (ringRead=%df of want=%df)\n",
                    (unsigned long long)call, silent ? "true" : "false", branch, got, want);
        }
        fflush(stdout);
    }
#else
    void logAudioBranch(const char *, bool, int32_t, int32_t) { }
#endif

    // Underruns are logged DISTINCTLY from the periodic line (they are the "audio is missing" signal,
    // not a drift datum) but throttled to ~1/s: a video-only file, or a long pause outside the ring's
    // window, would otherwise emit at the 50 Hz callback rate.
    void logUnderrunThrottled(double srcTime, int32_t want) {
        if (m_audioStreamFrames - m_lastUnderrunLogFrames < (BMDTimeValue)m_audio.sampleRate) return;
        m_lastUnderrunLogFrames = m_audioStreamFrames;
        fprintf(stdout, "DeckLinkAudio: !! UNDERRUN — ring has nothing at srcT=%.3fs (wanted %df); "
                        "scheduling silence, will re-anchor (total=%llu)\n",
                srcTime, want, (unsigned long long)m_underruns);
        fflush(stdout);
    }

    // UNDERRUN EVENTS (docs/AUDIO_RESAMPLER_DESIGN.md §19.12). `m_underruns` counts CALLBACKS, and
    // one dropout is usually several: after an empty read the cursor re-anchors to `ideal`, which is
    // already past a head that has not moved, so the next 1–3 callbacks are empty too. An EVENT is
    // one run of consecutive empty-ring callbacks — one hole in the programme — and it is what a
    // listener hears. Logged once, when the run ends (the next real read), unthrottled: with the
    // file pumps' tap look-ahead there should be none mid-file, so each one is worth a line.
    void noteUnderrunCallback(int32_t want) {
        if (!m_inUnderrunEvent) {
            m_inUnderrunEvent = true;
            m_underrunEvents++;
            m_eventStartSrcT = m_cursorSeconds;
            m_eventCallbacks = 0;
            m_eventSilenceFrames = 0;
        }
        m_eventCallbacks++;
        m_eventSilenceFrames += (uint64_t)std::max(want, 0);
    }

    void endUnderrunEventIfAny() {
        if (!m_inUnderrunEvent) return;
        m_inUnderrunEvent = false;
        fprintf(stdout, "DeckLinkAudio: !! UNDERRUN EVENT #%llu ended — began at srcT=%.3fs, %u callback%s, "
                        "%lluf of silence (%.0f ms) · events=%llu underrunCallbacks=%llu\n",
                (unsigned long long)m_underrunEvents, m_eventStartSrcT, m_eventCallbacks,
                m_eventCallbacks == 1 ? "" : "s", (unsigned long long)m_eventSilenceFrames,
                (double)m_eventSilenceFrames * 1000.0 / (double)m_audio.sampleRate,
                (unsigned long long)m_underrunEvents, (unsigned long long)m_underruns);
        fflush(stdout);
    }

    CallResult fillFrame(IDeckLinkMutableVideoFrame *frame, int64_t frameIndex) {
        IDeckLinkVideoBuffer *buffer = NULL;
        HRESULT hr = frame->QueryInterface(IID_IDeckLinkVideoBuffer, (void **)&buffer);
        if (hr != S_OK || buffer == NULL) return { "QueryInterface(IDeckLinkVideoBuffer)", hr != S_OK ? hr : E_POINTER };
        hr = buffer->StartAccess(bmdBufferAccessWrite);
        if (hr != S_OK) { buffer->Release(); return { "StartAccess", hr }; }
        void *bytes = NULL;
        hr = buffer->GetBytes(&bytes);
        if (hr != S_OK || bytes == NULL) {
            buffer->EndAccess(bmdBufferAccessWrite); buffer->Release();
            return { "GetBytes", hr != S_OK ? hr : E_POINTER };
        }
        // Pluggable — no DeckLink knowledge. A picture brings its own signal; a neutral fill keeps the one in force
        // (S7 D5). Preroll (start thread) and completions (SDK thread) never overlap: completions begin only after
        // StartScheduledPlayback, so `m_signal` needs no lock.
        DeckLinkOutputSignal signal = m_signal;
        if (m_fill(frameIndex, (uint8_t *)bytes, m_rowBytes, m_width, m_height, &signal)) m_signal = signal;
        buffer->EndAccess(bmdBufferAccessWrite);
        buffer->Release();
        noteHandedFrame(frameIndex);
        return { "GetBytes", S_OK };
    }

    // The audio anchor's frame (docs/CARD_CLOCK_FINDINGS.md §10.21): after each fill, the pts the fill handed the card (the
    // renderer's `currentDeckLinkSourcePts`, the same read the anchor made before) and the slot it went out in. Fills run on
    // the start thread during preroll and on the SDK's video thread after; the audio callback reads, so under a lock.
    void noteHandedFrame(int64_t idx) {
        if (!m_audioEnabled || !m_audio.sourceTime) return;
        if (m_audio.handed) {
            // Stage 1c: every slot, in order, for the audio callback's runs (§10.22). A fill that handed nothing new (a neutral or
            // held picture) is a slot with no frame of the run.
            double hp = NAN, due = NAN, srcFrame = 0; bool timed = false, byTime = false; uint64_t seq = 0;
            m_audio.handed(&hp, &timed, &byTime, &seq, &due, &srcFrame);
            const bool handed = seq != m_lastHandSeq;
            m_lastHandSeq = seq;
            m_byTime.store(byTime);
            os_unfair_lock_lock(&m_handedLock);
            m_slots[m_slotWrites % kSlotRing] = Slot{ idx, handed ? hp : NAN, handed && timed, handed, handed && timed ? due : NAN, srcFrame };
            m_slotWrites++;
            os_unfair_lock_unlock(&m_handedLock);
        }
        const double pts = m_audio.sourceTime();
        os_unfair_lock_lock(&m_handedLock);
        if (!std::isfinite(pts)) { m_handedPts = NAN; m_handedFirstIdx = m_handedLastIdx = -1; }
        else if (pts != m_handedPts || m_handedFirstIdx < 0) { m_handedPts = pts; m_handedFirstIdx = m_handedLastIdx = idx; }
        else m_handedLastIdx = idx;
        os_unfair_lock_unlock(&m_handedLock);
    }

    // ===== Stage 1c: a file's sound on the card's own timeline (docs/CARD_CLOCK_FINDINGS.md §10.20, §10.22) =====================
    //
    // A RUN is a stretch of play whose picture follows one line, slot idx ↔ source time Φ + idx × frame. Inside it, card sample s
    // carries source sample s + D, D = round(Φ × rate): one mapping, so each frame gets exactly its samples (800/801 at 59.94) and
    // nothing is steered. A run starts (LATCH) at the first timed slot whose picture moved, with the gate open; its sound starts with
    // the slot before when that slot showed the frame just before (at a Play, the paused frame's last showing). It ends at the first
    // slot off the line whose pull was not timed (pause, seek, step, loop wrap, shuttle), at that slot's first sample.
    // EDGES: audio is queued ~200 ms ahead and the picture ~3 frames, so an edge lands inside what is already scheduled. A flush
    // removes all but the ~110 ms the card has committed, and the card ADDS whatever is scheduled into that committed window
    // (C0, §10.22). So the edge schedules (desired − what was scheduled) there, from the history ring, and schedules normally after it.
    // Gate on only (the card is the file's clock): a timed slot off the line ends the run, logged; expected never in play. With the
    // gate off a file keeps the §10.21 loop (§10.20; the runs' gate-off steering was measured and dropped, §10.22). The !cardTimeline
    // branches below are therefore not reached.

    int64_t A(int64_t n) const { return n * (int64_t)m_audio.sampleRate * (int64_t)m_frameDuration / (int64_t)m_timeScale; }
    double samplesPerSlot() const { return (double)m_audio.sampleRate * (double)m_frameDuration / (double)m_timeScale; }
    double cardFrameSeconds() const { return (double)m_frameDuration / (double)m_timeScale; }

    // ----- Rate mismatch (C6, docs/CARD_CLOCK_FINDINGS.md §10.23): a source frame that is not one card frame (25p, 23.976 or 29.97
    // on 59.94; 23.976 on 24.000). The picture is a staircase: a frame is first shown at the first slot whose due time (the pull's
    // target plus its hysteresis, `Slot::due`) reaches its pts, and repeated until the next one is due. One run is still one mapping,
    // s + D, so the sound stays continuous across every cadence step; only the picture repeats.
    bool mismatched(double srcFrame) const { return srcFrame > 0 && std::fabs(srcFrame / cardFrameSeconds() - 1.0) > 5e-4; }

    // The sound's line is the picture's LOWER ENVELOPE: the latest mapping under which no frame's sound starts after its first showing,
    // D = max over the frames of (pts × rate − i × samples per slot). At matched rates every frame has the same phase and this is the
    // frame grid, as `latchRun` takes it; at 2:1 and 5:2 (29.97 and 23.976 on 59.94) the phases are 1 or 2 and it is again a frame's
    // own grid; at 25p on 59.94 (2400/1001 slots a frame) the phases fill the slot and it is the due line to under a sample. Taken over
    // 2002 frames, beyond every period here (1001 at 25p on 59.94, 1000 at 23.976 on 24.000).
    int64_t envelopeD(double phi, double pts0, double fs) const {
        const double fc = cardFrameSeconds(), rate = (double)m_audio.sampleRate, spf = samplesPerSlot();
        double best = -INFINITY;
        for (int k = 0; k < 2002; k++) {
            const double p = pts0 + k * fs;
            const double i = std::ceil((p - phi) / fc - 1e-6);   // the first slot whose due time reaches p
            best = std::max(best, p * rate - i * spf);
        }
        return llround(best);
    }

    // The picture's line from one timed slot: its due time carried back to slot 0, never below what that slot showed (a frame is
    // shown only once due).
    double lineFrom(const Slot &sl) const {
        const double fc = cardFrameSeconds();
        const double lower = sl.pts - (double)sl.idx * fc;
        return std::isfinite(sl.due) ? std::max(sl.due - (double)sl.idx * fc, lower) : lower;
    }

    // Is `sl` the frame the run's picture line shows at its slot? Within 1 ms of a frame's due time either neighbour is accepted (the
    // pull's slot clock wobbles about 0.4 ms).
    bool onCadLine(const Run &r, const Slot &sl) const {
        const double due = r.phi + (double)sl.idx * cardFrameSeconds();
        const double k = std::floor((due - r.pts0) / r.fs + 1e-6);
        const double pred = r.pts0 + k * r.fs;
        if (std::fabs(sl.pts - pred) < 0.0005) return true;
        if ((pred + r.fs) - due < 0.001 && std::fabs(sl.pts - (pred + r.fs)) < 0.0005) return true;
        if (due - pred < 0.001 && std::fabs(sl.pts - (pred - r.fs)) < 0.0005) return true;
        return false;
    }

    // The sound card position `a` should carry, for n positions, into `dst` (wire layout). Zero outside every run and under the gate.
    void fillDesired(int64_t a, int32_t n, bool silent, int32_t *dst, int64_t &pcm, int64_t &missing, int64_t *firstMissing = nullptr) {
        const uint32_t sc = m_audio.srcChannels, dc = m_audio.dlChannels;
        memset(dst, 0, (size_t)n * dc * sizeof(int32_t));
        // The gate does not cut a run: its sound plays until the picture leaves the line (pause, seek, shuttle end the run there),
        // so it stops with the last frame that moved. A gate silent while the picture keeps moving (mute, destination Computer)
        // ends the run after kGateSlots slots (processSlots). Outside a run there is nothing to play.
        (void)silent;
        if (n <= 0) return;
        for (const Run *r : { &m_prev, &m_run }) {
            if (!r->valid) continue;
            const int64_t lo = std::max(a, r->start), hi = std::min(a + (int64_t)n, r->end);
            if (lo >= hi) continue;
            int32_t *src = m_srcScratch.data();
            const double rate = (double)m_audio.sampleRate;
            auto readAt = [&](int64_t p, int32_t k) { return m_audio.read ? std::max(0, m_audio.read((double)(p + r->D) / rate, k, src)) : 0; };
            // The ring answers 0 for a read that starts before what it holds, so after a seek the chunk holding the first decoded sample
            // would read as empty: find where the data starts, 1 ms at a time (and the chunk's last position), then back one sample at a
            // time to the first that holds data, and read from there. The coarse step alone lost up to 47 samples at a seek (§10.22).
            int64_t from = lo;
            int32_t got = readAt(from, (int32_t)(hi - from));
            if (got == 0 && hi - lo > 1) {
                int64_t hit = -1;
                for (int64_t q = lo + 48; q < hi; q += 48) if (readAt(q, 1) == 1) { hit = q; break; }
                if (hit < 0 && readAt(hi - 1, 1) == 1) hit = hi - 1;
                if (hit >= 0) {
                    const int64_t stop = std::max(lo + 1, hit - 47);   // stop − 1 is known to hold nothing (lo, or the last coarse step)
                    int64_t q = hit;
                    while (q > stop && readAt(q - 1, 1) == 1) q--;
                    if (q < hit) { m_fineStarts++; m_fineRecovered += hit - q; }
                    from = q; got = readAt(from, (int32_t)(hi - from));
                }
            }
            for (int32_t f = 0; f < got; f++)
                for (uint32_t c = 0; c < sc; c++) dst[(size_t)(from - a + f) * dc + c] = src[(size_t)f * sc + c];
            // What the tap no longer has (a seek empties it while the old run still has frames to play): the prefetch ring.
            int32_t fromPre = 0;
            if (!m_pre.empty()) {
                for (int64_t q = lo; q < hi; q++) {
                    if (q >= from && q < from + got) continue;
                    const size_t slot = (size_t)(q % kPreFrames);
                    if (m_preKey[slot] != q || m_preRun[slot] != r->serial) continue;
                    for (uint32_t c = 0; c < sc; c++) dst[(size_t)(q - a) * dc + c] = m_pre[slot * sc + c];
                    fromPre++;
                }
            }
            got += fromPre;
            pcm += got; missing += (hi - lo) - got;
            if (firstMissing && (hi - lo) - got > 0) {
                const int64_t fm = got > 0 && from > lo ? lo : (got > 0 ? from + got : lo);
                *firstMissing = std::min(*firstMissing, fm);
            }
        }
    }

    void remember(int64_t a, int32_t n, const int32_t *frames) {
        const uint32_t dc = m_audio.dlChannels;
        for (int32_t f = 0; f < n; f++)
            memcpy(&m_hist[(size_t)((a + f) % kHistFrames) * dc], frames + (size_t)f * dc, dc * sizeof(int32_t));
    }

    // Make every position from `edge` on carry what the runs now say. Returns how late the rewrite started, in samples (0: on time).
    // NO FLUSH (§10.22, C0 and C0b): a flush cannot remove the ~100 ms the card has committed, and where that window ends is known only
    // to ±2 samples, which left a stray sample of the old sound in the silence after a Pause. With the queue held under the committed
    // window (kRunsDepthFrames), every queued sample is committed, and the card ADDS what is scheduled over it: so (desired − what was
    // scheduled there, from the history ring) leaves exactly the desired sound, from 1 ms past the card's position to the queue's end.
    // `remap`: a mapping change inside a run, rewritten from 1 ms past the card by design; not a late edge.
    int64_t rewriteFrom(int64_t edge, bool silent, const char *why, bool quiet = false, bool remap = false) {
        if (edge >= m_audioStreamFrames) return 0;   // not scheduled yet: the top-up will write it
        BMDTimeValue now = 0; double speed = 0; uint32_t buffered = 0;
        m_output->GetScheduledStreamTime((BMDTimeScale)m_audio.sampleRate, &now, &speed);
        m_output->GetBufferedAudioSampleFrameCount(&buffered);
        // Nothing below the stream's first scheduled position exists to rewrite (after an output-start restart, §10.24).
        const int64_t lo = std::max<int64_t>({ edge, (int64_t)now + kEdgeGuardFrames, m_audioOrigin }), hi = m_audioStreamFrames;
        int64_t pcm = 0, missing = 0, written = 0, firstMissing = INT64_MAX;
        for (int64_t a = lo; a < hi; ) {
            const int32_t n = (int32_t)std::min<int64_t>(hi - a, m_maxCallbackFrames);
            int32_t *dst = m_outScratch.data();
            fillDesired(a, n, silent, dst, pcm, missing, &firstMissing);
            const uint32_t dc = m_audio.dlChannels;
            for (int64_t i = 0; i < (int64_t)n * dc; i++) {
                const size_t h = (size_t)((a + i / dc) % kHistFrames) * dc + (size_t)(i % dc);
                const int64_t want = dst[i], had = m_hist[h];
                m_hist[h] = (int32_t)want;
                dst[i] = (int32_t)std::max<int64_t>(INT32_MIN, std::min<int64_t>(INT32_MAX, want - had));
            }
            uint32_t w = 0;
            m_output->ScheduleAudioSamples(dst, (uint32_t)n, a, (BMDTimeScale)m_audio.sampleRate, &w);
            written += w;
            if (w < (uint32_t)n) { m_shortSchedules++; break; }
            a += n;
        }
        // §10.24, item 5: the card ADDS a rewrite into what it holds, so its queued count does not grow. Once in chain13 (c6-tr-2398,
        // a Pause) it APPENDED the rewrite after the queue's end instead: the sound ran on by the rewrite's length, then its inverse.
        // Detected here from the queued count (grown by more than half of what was written); logged, no correction yet.
        if (written > 0) {
            uint32_t after = 0; m_output->GetBufferedAudioSampleFrameCount(&after);
            if ((int64_t)after > (int64_t)buffered + written / 2) {
                m_appendedEdges++;
                fprintf(stdout, "[SDI-AUDIO] !! edge (%s) at stream %lld APPENDED by the card, not added: queued %u before the rewrite, %u after, "
                                "%lld samples rewritten (%lld..%lld)\n",
                        why, (long long)edge, buffered, after, (long long)written, (long long)lo, (long long)hi);
                fflush(stdout);
            }
        }
        m_pendingFrom = firstMissing == INT64_MAX ? -1 : firstMissing;   // still to fill when the sound arrives
        if (quiet) { if (pcm > 0) m_filledLate += pcm; return 0; }
        const int64_t late = remap ? 0 : std::max<int64_t>(0, lo - edge);
        if (late > 0) { m_lateEdges++; m_lateEdgeFrames += late; }
        if (buffered > (uint32_t)kRunsCommittedFrames) m_deepEdges++;
        fprintf(stdout, "[SDI-AUDIO] edge (%s) at stream %lld: now %lld, queued %u to %lld; rewrote %lld..%lld (%lld written, %lld of them sound, "
                        "%lld missing), late %lld samples%s\n",
                why, (long long)edge, (long long)now, buffered, (long long)hi, (long long)lo, (long long)hi, (long long)written, (long long)pcm,
                (long long)missing, (long long)late, buffered > (uint32_t)kRunsCommittedFrames ? " · QUEUE DEEPER THAN THE COMMITTED WINDOW" : "");
        fflush(stdout);
        return late;
    }

    void latchRun(const Slot &slot, int64_t startSlot, bool withPrev, bool silent, const char *why) {
        const double spf = samplesPerSlot();
        const int64_t D = llround(slot.pts * (double)m_audio.sampleRate - (double)slot.idx * spf);
        Run r; r.valid = true; r.start = A(startSlot); r.end = INT64_MAX; r.D = D; r.serial = ++m_runSerial; m_preTo = r.start;
        r.confirmed = false; r.lineIdx = slot.idx; r.pts0 = slot.pts;   // provisional until the next timed slot (confirmRun)
        m_run = r; m_runActive = true; m_errEma = 0.0; m_steerErr = NAN; m_latches++; m_gateSlots = 0;
        BMDTimeValue now = 0; double speed = 0;
        m_output->GetScheduledStreamTime((BMDTimeScale)m_audio.sampleRate, &now, &speed);
        fprintf(stdout, "[SDI-AUDIO] latch #%llu (%s): line from slot %lld pts %.6f, sound from slot %lld%s, D %lld, from stream %lld (source %.6f s); now %lld; "
                        "gate opened at %lld, so %lld samples (%.1f ms) of silence before the sound%s\n",
                (unsigned long long)m_latches, why, (long long)slot.idx, slot.pts, (long long)startSlot, withPrev ? " (the held frame's last showing)" : "",
                (long long)D, (long long)r.start, (double)(r.start + D) / m_audio.sampleRate, (long long)now, (long long)m_gateOpenAt,
                (long long)(m_gateOpenAt >= 0 ? r.start - m_gateOpenAt : -1), m_gateOpenAt >= 0 ? (r.start - m_gateOpenAt) / (m_audio.sampleRate / 1000.0) : -1.0,
                m_audioStreamFrames > r.start ? "; rewriting what is queued" : "");
        fflush(stdout);
        const int64_t late = rewriteFrom(r.start, silent, "latch");
        noteRunStart(r.start + late, D);
        m_gateOpenAt = -1;
    }

    // C6: a run at a rate mismatch latches on the first slot that moved, at once: the next frame that moves can be 2 or 3 slots on,
    // too late for the sound's start. Its frame grid is confirmed on that next frame (`processSlots`).
    void latchCad(const Slot &slot, int64_t startSlot, bool withPrev, bool silent, const char *why) {
        Run r; r.valid = true; r.cad = true; r.confirmed = false; r.fs = slot.srcFrame; r.pts0 = slot.pts; r.phi = lineFrom(slot);
        r.lineIdx = slot.idx;
        // §10.24: the latch slot is the run's first showing; its bounds start the check that every later first showing continues
        // (`observeCad`). lineFrom already keeps phi at or above the lower one.
        r.lo = slot.pts - (double)slot.idx * cardFrameSeconds();
        r.hi = withPrev ? r.lo + cardFrameSeconds() : INFINITY;
        if (r.phi >= r.hi) r.above = 1;
        r.D = envelopeD(r.phi, r.pts0, r.fs);
        r.start = A(startSlot); r.end = INT64_MAX; r.serial = ++m_runSerial; m_preTo = r.start;
        m_run = r; m_runActive = true; m_errEma = 0.0; m_steerErr = NAN; m_latches++; m_cadRuns++; m_gateSlots = 0;
        BMDTimeValue now = 0; double speed = 0;
        m_output->GetScheduledStreamTime((BMDTimeScale)m_audio.sampleRate, &now, &speed);
        const double rate = (double)m_audio.sampleRate;
        fprintf(stdout, "[SDI-AUDIO] latch #%llu (%s): rate mismatch, source frame %.6f s on a card frame %.6f s; line from slot %lld pts %.6f "
                        "due %.6f (phi %.6f), sound from slot %lld%s, D %lld (the slot's own %.1f; envelope %+.1f samples), from stream %lld (source %.6f s); "
                        "now %lld; gate opened at %lld, so %lld samples (%.1f ms) of silence before the sound%s\n",
                (unsigned long long)m_latches, why, r.fs, cardFrameSeconds(), (long long)slot.idx, slot.pts, slot.due, r.phi, (long long)startSlot,
                withPrev ? " (the held frame's last showing)" : "", (long long)r.D, slot.pts * rate - (double)slot.idx * samplesPerSlot(),
                (double)r.D - (slot.pts * rate - (double)slot.idx * samplesPerSlot()), (long long)r.start, (double)(r.start + r.D) / rate,
                (long long)now, (long long)m_gateOpenAt, (long long)(m_gateOpenAt >= 0 ? r.start - m_gateOpenAt : -1),
                m_gateOpenAt >= 0 ? (r.start - m_gateOpenAt) / (rate / 1000.0) : -1.0, m_audioStreamFrames > r.start ? "; rewriting what is queued" : "");
        fflush(stdout);
        const int64_t late = rewriteFrom(r.start, silent, "latch");
#ifdef DEBUG
        if (kAudioCorrLog) {
            const int64_t first = r.start + late;
            fprintf(stdout, "[AUDIO-CORR] s=%lld n=0 got=0 c=0 k=a e=+0.000 cur=%.6f\n", (long long)first, (double)(first + r.D) / rate);
        }
#endif
        m_gateOpenAt = -1;
    }

    // C6: the next frame that moved, `sl`, checks the run's frame grid. One source frame after the latch's: confirmed, and the frame
    // duration taken from the two pts (exact, the file's own). Otherwise the latch's frame was off the grid (the first frame after a
    // seek carries the seek's time, §10.22): the line is taken from this one, D recomputed, and what is queued rewritten from the
    // run's start or 1 ms past the card, whichever is later. Logged and counted.
    void confirmCad(const Slot &sl, bool silent) {
        const double step = sl.pts - m_run.pts0;
        const double steps = std::round(step / m_run.fs);
        if (steps >= 1 && std::fabs(step - steps * m_run.fs) < 0.0001) {
            m_run.fs = step / steps;
            m_run.confirmed = true;
            const int64_t D = envelopeD(m_run.phi, m_run.pts0, m_run.fs);
            if (D == m_run.D) return;
            fprintf(stdout, "[SDI-AUDIO] rate mismatch: frame %.9f s from the pts (hint %.9f): D %lld → %lld\n", m_run.fs, sl.srcFrame,
                    (long long)m_run.D, (long long)D);
            m_run.D = D;
        } else {
            m_cadGridFixes++;
            const int64_t was = m_run.D;
            m_run.pts0 = sl.pts; m_run.phi = lineFrom(sl); m_run.lineIdx = sl.idx; m_run.confirmed = true;
            m_run.lo = -INFINITY; m_run.hi = INFINITY; m_run.above = 0;   // the latch frame's bounds were the seek's time, not the line's
            m_run.D = envelopeD(m_run.phi, m_run.pts0, m_run.fs);
            fprintf(stdout, "[SDI-AUDIO] rate mismatch: the latch's frame was off the grid (step %.6f s, frame %.6f s): line from slot %lld pts %.6f, "
                            "D %lld → %lld\n", step, m_run.fs, (long long)sl.idx, sl.pts, (long long)was, (long long)m_run.D);
            if (m_run.D == was) return;
        }
        fflush(stdout);
        m_preTo = m_run.start; m_run.serial = ++m_runSerial;   // the prefetch holds the old mapping's sound
        rewriteFrom(m_run.start, silent, "rate mismatch: grid confirmed");
    }

    // C6 follow-up (§10.24, item 2): the run's line checked against every first showing, not taken from one slot's due time at the
    // latch. A frame shown before its sound (phi under the frames' lower bound by more than 2 samples) moves the line up at once;
    // frames shown a slot later than the line says (phi at or past the upper bound) move it down on the second in a row, since a
    // single one can be the pull's hysteresis choosing the frame after. A move that changes D rewrites what is queued from 1 ms past
    // the card, logged and counted. Fixes c6-tr-2997's run a card frame late after the loop seek, and the 25p first showings up to
    // 0.18 ms before their sound as the pull's due line wandered under steering (§10.23).
    // A frame more than a card frame off the line is not this run's (a seek that lands on the run's grid, chain14 c614-tr-25): the
    // line check ends the run. A D that moves by kCadRewriteTolFrames or less (0.083 ms at 48 kHz, inside the ±0.1 ms target) is
    // kept: the line moves, the queue is not rewritten, since each rewrite is a step of that size on the wire (11 in 600 s at 25p).
    static constexpr int64_t kCadRewriteTolFrames = 4;
    void observeCad(const Slot &sl, bool prevEarlier, bool silent) {
        Run &r = m_run;
        const double k = std::round((sl.pts - r.pts0) / r.fs);
        if (k < 0 || std::fabs(sl.pts - (r.pts0 + k * r.fs)) > 0.0005) return;   // not a frame of the run's grid: the line check handles it
        const double fc = cardFrameSeconds(), rate = (double)m_audio.sampleRate;
        const double lo = sl.pts - (double)sl.idx * fc, hi = prevEarlier ? lo + fc : INFINITY;
        if (lo > r.phi + fc || lo < r.phi - 2.0 * fc) return;
        r.lo = std::max(r.lo, lo); r.hi = std::min(r.hi, hi);
        if (r.lo >= r.hi) { r.lo = lo; r.hi = hi; }   // the line moved under the pull's steering: the latest showing stands
        double phi = r.phi; const char *why = nullptr;
        if (phi < r.lo - 2.0 / rate) { phi = r.lo; why = "a frame shown before its sound"; }
        else if (phi >= r.hi) {
            if (++r.above >= 2) { phi = std::max(r.lo, r.hi - 1.0 / rate); why = "frames shown a slot later than the line says"; }
        } else r.above = 0;
        if (!why) return;
        r.above = 0;
        const double was = r.phi;
        r.phi = phi;
        const int64_t D = envelopeD(r.phi, r.pts0, r.fs);
        if (std::llabs(D - r.D) <= kCadRewriteTolFrames) return;
        m_cadRederives++;
        fprintf(stdout, "[SDI-AUDIO] rate mismatch: line from the first showings (%s): slot %lld pts %.6f, bounds [%.6f, %.6f), phi %.6f → %.6f, "
                        "D %lld → %lld (%+lld samples)\n", why, (long long)sl.idx, sl.pts, r.lo, r.hi, was, r.phi, (long long)r.D, (long long)D,
                (long long)(D - r.D));
        fflush(stdout);
        r.D = D; m_preTo = r.start; r.serial = ++m_runSerial;   // the prefetch holds the old mapping's sound
        rewriteFrom(r.start, silent, "rate mismatch: line from the first showings", false, true);
    }

    // §10.25 item 4: a matched-rate run latches on the first slot that moved, at once, so its sound reaches the card while that slot is
    // still ahead of it. Until 2026-11-11 the latch waited for the next slot's one-frame step, and when the first frame was held (a loop
    // wrap shows frame 0 twice) or the sound started at the held frame's last showing, it reached the card 78–126 samples after the
    // run's start (three runs at 59.94, §10.24). The next timed slot after the line's (`sl`, one slot on) settles it:
    //   - one frame on: confirmed;
    //   - the same frame (the first frame held): the sound starts at its last showing, as a latch on the next frame would have put it;
    //     the start moves to this slot and the queue is rewritten from the old start (still ahead of the card: one slot later than
    //     before, it was in time in every run);
    //   - off the frame step by under half a frame (the first frame after a seek can carry the seek's time, 600.000000 for the frame
    //     at 599.999396): the line is taken from this slot, the start kept, as the candidate did before;
    //   - anything else: settled as confirmed, and the slot is checked against the line as any other (a jump ends the run and
    //     re-latches here).
    // Returns true when the slot was taken here (not to be checked against the line).
    bool confirmRun(const Slot &sl, bool moved, bool silent) {
        const double spf = samplesPerSlot(), rate = (double)m_audio.sampleRate;
        if (sl.idx != m_run.lineIdx + 1) { m_run.confirmed = true; return false; }
        if (!moved && sl.pts == m_run.pts0 && ++m_run.tries <= (int)kAudioMaxRepeatSlots) {
            const int64_t was = m_run.start;
            m_run.lineIdx = sl.idx; m_run.start = A(sl.idx);
            m_run.D = llround(sl.pts * rate - (double)sl.idx * spf);
            m_run.serial = ++m_runSerial; m_preTo = m_run.start; m_provHolds++;
            // Late only if the card has passed the NEW start (passing the old one only cuts silence short): measured here, and the
            // rewrite from the old start is a remap so rewriteFrom does not count it against the old one.
            BMDTimeValue now = 0; double speed = 0;
            m_output->GetScheduledStreamTime((BMDTimeScale)m_audio.sampleRate, &now, &speed);
            const int64_t late = std::max<int64_t>(0, (int64_t)now + kEdgeGuardFrames - m_run.start);
            if (late > 0) { m_lateEdges++; m_lateEdgeFrames += late; }
            fprintf(stdout, "[SDI-AUDIO] latch #%llu: the first frame (pts %.6f) held at slot %lld; sound from it, D %lld, from stream %lld; "
                            "now %lld, late %lld samples\n", (unsigned long long)m_latches, sl.pts, (long long)sl.idx, (long long)m_run.D,
                    (long long)m_run.start, (long long)now, (long long)late);
            fflush(stdout);
            rewriteFrom(was, silent, "latch: first frame held", false, true);
            noteRunStart(m_run.start + late, m_run.D);
            return true;
        }
        const double step = moved ? (sl.pts - m_run.pts0) * rate - spf : NAN;
        if (moved && std::fabs(step) >= 2.0 && std::fabs(step) < spf * 0.5 && ++m_run.tries <= 3) {
            const int64_t D = llround(sl.pts * rate - (double)sl.idx * spf);
            m_run.lineIdx = sl.idx; m_run.pts0 = sl.pts; m_provRederives++;
            fprintf(stdout, "[SDI-AUDIO] latch #%llu: the latch frame was off the grid by %+.1f samples; line from slot %lld pts %.6f, D %lld → %lld\n",
                    (unsigned long long)m_latches, step, (long long)sl.idx, sl.pts, (long long)m_run.D, (long long)D);
            fflush(stdout);
            if (D != m_run.D) {
                m_run.D = D; m_run.serial = ++m_runSerial; m_preTo = m_run.start;
                const int64_t late = rewriteFrom(m_run.start, silent, "latch: line from the next frame");
                noteRunStart(m_run.start + late, m_run.D);
            }
            return true;
        }
        m_run.confirmed = true;
        return false;
    }

    // [AUDIO-CORR] the run's first sample on the card's stream, for w1c-wire.py's s0.
    void noteRunStart(int64_t first, int64_t D) {
#ifdef DEBUG
        if (kAudioCorrLog)
            fprintf(stdout, "[AUDIO-CORR] s=%lld n=0 got=0 c=0 k=a e=+0.000 cur=%.6f\n", (long long)first, (double)(first + D) / m_audio.sampleRate);
#else
        (void)first; (void)D;
#endif
    }

    void endRun(int64_t idx, bool silent, const char *why) { endRunAt(A(idx), idx, silent, why); }
    void endRunAt(int64_t end, int64_t idx, bool silent, const char *why) {
        m_run.end = end;
        m_prev = m_run; m_run = Run(); m_runActive = false; m_steerErr = NAN; m_runEnds++;
        fprintf(stdout, "[SDI-AUDIO] run end (%s) at slot %lld: sound to stream %lld (source %.6f s)\n",
                why, (long long)idx, (long long)m_prev.end, (double)(m_prev.end + m_prev.D) / m_audio.sampleRate);
        fflush(stdout);
        rewriteFrom(m_prev.end, silent, why);
    }

    // The slots handed since the last callback, in order.
    void processSlots(bool silent, bool live, uint32_t buffered) {
        Slot local[kSlotRing]; int n = 0;
        os_unfair_lock_lock(&m_handedLock);
        const uint64_t w = m_slotWrites;
        uint64_t lost = 0;
        if (w - m_slotReads > (uint64_t)kSlotRing) { lost = w - m_slotReads - kSlotRing; m_slotReads = w - kSlotRing; }
        for (uint64_t k = m_slotReads; k < w; k++) local[n++] = m_slots[k % kSlotRing];
        m_slotReads = w;
        os_unfair_lock_unlock(&m_handedLock);
        if (lost && m_runActive && live && n) endRun(local[0].idx, silent, "slots lost");
        const double spf = samplesPerSlot(), rate = (double)m_audio.sampleRate;
        for (int k = 0; k < n; k++) {
            const Slot &sl = local[k];
            const bool hasPts = sl.handed && std::isfinite(sl.pts);
            const bool moved = hasPts && sl.pts != m_prevSlotPts;
            bool endedHere = false;
            if (live && m_runActive && m_run.cad && hasPts && sl.timed && moved && !m_run.confirmed) {
                confirmCad(sl, silent);   // the grid first, then this slot is checked against it
            }
            if (live && m_runActive && m_run.cad && m_run.confirmed && hasPts && sl.timed && moved) {
                const bool prevEarlier = m_prevSlotIdx == sl.idx - 1 && std::isfinite(m_prevSlotPts) && m_prevSlotPts < sl.pts;
                observeCad(sl, prevEarlier, silent);   // then the line, from this first showing
            }
            const bool provisional = live && m_runActive && !m_run.cad && !m_run.confirmed && hasPts && sl.timed && confirmRun(sl, moved, silent);
            if (live && m_runActive && !provisional) {
                const double e = hasPts ? sl.pts * rate - ((double)sl.idx * spf + (double)m_run.D) : NAN;
                const bool onLine = m_run.cad ? hasPts && onCadLine(m_run, sl) : hasPts && std::fabs(e) <= spf * 0.5;
                if (m_run.cad && onLine && sl.timed && moved) {
                    // The envelope promises no frame is shown before its sound starts: e ≤ 0 at every first showing. Counted if not.
                    if (e > 2.0) {
                        m_envMisses++; m_envWorst = std::max(m_envWorst, e);
                        if (m_envMisses <= 5)
                            fprintf(stdout, "[SDI-AUDIO] rate mismatch: slot %lld pts %.6f shown %.1f samples before its sound starts\n",
                                    (long long)sl.idx, sl.pts, e);
                    }
                }
                if (onLine) {
                    if (sl.timed && moved) m_steerErr = e;
                    // The gate silent while the picture stays on the line: a mute, or the destination moved to the Mac.
                    if (silent && ++m_gateSlots >= kGateSlots) {
                        BMDTimeValue now = 0; double speed = 0;
                        m_output->GetScheduledStreamTime((BMDTimeScale)m_audio.sampleRate, &now, &speed);
                        endRunAt((int64_t)now + kEdgeGuardFrames, sl.idx, silent, "gate silent with the picture moving: mute or destination");
                    }
                    if (!silent) m_gateSlots = 0;
                } else if (hasPts && sl.timed && !m_audio.cardTimeline) {
                    m_steerErr = e;   // gate off: a picture slip; the loop walks the sound to it
                } else {
                    // Off the run's line. On a timed pull under card lock that is not expected in play; it is seen as the picture
                    // stepping back a frame on the pull before a seek or a loop's wrap. Counted apart; a new run latching on this very
                    // slot is a re-latch.
                    if (hasPts && sl.timed) {
                        m_timedEnds++;
                        fprintf(stdout, "[SDI-AUDIO] off the line on a timed pull: slot %lld pts %.6f is %+.1f samples off%s\n", (long long)sl.idx, sl.pts, e,
                                m_run.cad ? " (rate mismatch: not the frame the run's line shows here)" : "");
                    }
                    endRun(sl.idx, silent, !sl.handed ? "no frame handed" : sl.timed ? "off the line on a timed pull" : "untimed pull");
                    endedHere = true;
                }
            }
            // A latch rewrites what is queued, so it waits until the queue is within the committed window (after output start, or
            // a switch from a live source, it is still the 200 ms of the live path). At matched rates it is provisional and settled on
            // the next timed slot (confirmRun): the first frame after a seek can carry the seek's time rather than its own
            // (600.000000 for the frame at 599.999400, §10.22), and a first frame can be held. Until §10.25 the latch itself waited
            // for that slot, and could reach the card after the run's start.
            if (live && !m_runActive && mismatched(sl.srcFrame)) {
                // C6: latch at once on the first timed slot that moved; the sound starts with the held frame's last showing when the
                // slot before showed the frame just before.
                const bool eligible = !silent && hasPts && sl.timed && moved && buffered <= (uint32_t)kRunsCommittedFrames;
                if (eligible) {
                    const bool fromPrev = m_prevSlotIdx == sl.idx - 1 && std::isfinite(m_prevSlotPts)
                        && std::fabs((sl.pts - m_prevSlotPts) - sl.srcFrame) * rate < 2.0;
                    if (endedHere) m_relatches++;
                    latchCad(sl, fromPrev ? sl.idx - 1 : sl.idx, fromPrev, silent, "first slot that moved");
                }
            } else if (live && !m_runActive) {
                // Matched rates: latch at once on the first timed slot that moved, provisionally; the next timed slot settles it
                // (confirmRun, §10.25 item 4). The sound starts with the held frame's last showing when the slot before showed the
                // frame just before. That frame can carry the seek's time rather than its own (1905.000000 for the frame at
                // 1904.986986, so a step of 149 samples to the next; 300.000000 held, then 300.016383: 786), and frames at a matched
                // rate are a frame apart otherwise, so any step forward under one and a half frames is the frame just before. Until
                // §10.25 the step had to be one frame (±2 samples), and Play after a seek, or a seek whose first frame was held, lost
                // that frame's sound (f15-tr-5994).
                const bool eligible = !silent && hasPts && sl.timed && moved && buffered <= (uint32_t)kRunsCommittedFrames;
                if (eligible) {
                    const double step = std::isfinite(m_prevSlotPts) ? (sl.pts - m_prevSlotPts) * rate : NAN;
                    const bool fromPrev = m_prevSlotIdx == sl.idx - 1 && std::isfinite(step) && step > 2.0 && step < spf * 1.5;
                    if (endedHere) m_relatches++;
                    latchRun(sl, fromPrev ? sl.idx - 1 : sl.idx, fromPrev, silent, "first slot that moved, provisional");
                }
            }
            m_prevSlotPts = hasPts ? sl.pts : NAN; m_prevSlotIdx = sl.idx;
        }
    }

    // Copy the current run's sound from the tap into the prefetch ring, up to kPrefetchFrames past the queue: at 23.976 the picture
    // is handed up to 125 ms ahead, beyond the 80 ms queue, and a seek empties the tap before the old run's last frames are scheduled.
    void prefetch() {
        if (!m_runActive || m_pre.empty() || !m_audio.read) return;
        const uint32_t sc = m_audio.srcChannels;
        const int64_t from = std::max({ m_preTo, m_audioStreamFrames, m_run.start });
        const int64_t to = std::min<int64_t>(m_audioStreamFrames + kPrefetchFrames, m_run.end);
        if (to <= from) return;
        const int32_t n = (int32_t)std::min<int64_t>(to - from, m_maxCallbackFrames);
        int32_t *src = m_srcScratch.data();
        const int32_t got = std::max(0, m_audio.read((double)(from + m_run.D) / (double)m_audio.sampleRate, n, src));
        for (int32_t f = 0; f < got; f++) {
            const size_t slot = (size_t)((from + f) % kPreFrames);
            m_preKey[slot] = from + f; m_preRun[slot] = m_run.serial;
            memcpy(&m_pre[slot * sc], src + (size_t)f * sc, sc * sizeof(int32_t));
        }
        m_preTo = from + got;   // a short read (not decoded yet) is tried again next callback
    }

    HRESULT renderRuns(bool preroll) {
        const double rate = (double)m_audio.sampleRate;
        const bool silent = m_audio.isSilent ? m_audio.isSilent() : true;
        const bool live = !preroll && m_playbackStarted.load();
        if (live && !silent && m_wasSilent) {
            BMDTimeValue now = 0; double speed = 0;
            m_output->GetScheduledStreamTime((BMDTimeScale)m_audio.sampleRate, &now, &speed);
            m_gateOpenAt = (int64_t)now;
        }
        m_wasSilent = silent;
        uint32_t queued = 0;
        m_output->GetBufferedAudioSampleFrameCount(&queued);
        processSlots(silent, live, queued);

        // Gate off only: steer D toward the exact error, as §10.21's loop (0 between slips: the error is under half a sample).
        int32_t correction = 0;
        if (live && m_runActive && !m_audio.cardTimeline && std::isfinite(m_steerErr)) {
            m_errEma += kAudioErrorEmaAlpha * (m_steerErr - m_errEma);
            if (std::fabs(m_errEma) > kAudioResyncSeconds * rate) {
                m_resyncs++;
                fprintf(stdout, "DeckLinkAudio: !! RESYNC (run) — smoothed error %+.1f ms; D %lld → %lld\n",
                        m_errEma / rate * 1000.0, (long long)m_run.D, (long long)(m_run.D + llround(m_steerErr)));
                fflush(stdout);
                m_run.D += llround(m_steerErr); m_errEma = 0.0; m_steerErr = 0.0;
            } else {
                correction = (int32_t)std::lround(std::max((double)-kAudioMaxCorrectionFrames,
                                                           std::min((double)kAudioMaxCorrectionFrames, m_errEma * 0.10)));
                if (correction) { m_run.D += correction; m_steerErr -= correction; m_errEma -= correction; }
            }
        }

        // Sound that was not decoded yet when its positions were scheduled (zeros): write it in once it is there, while it is still
        // ahead of the card. After a seek or a step the first ~100 ms are decoded only once play starts.
        if (live && m_pendingFrom >= 0) {
            BMDTimeValue now = 0; double speed = 0;
            m_output->GetScheduledStreamTime((BMDTimeScale)m_audio.sampleRate, &now, &speed);
            if (m_pendingFrom < (int64_t)now + kEdgeGuardFrames) m_pendingFrom = (int64_t)now + kEdgeGuardFrames;
            if (m_pendingFrom >= m_audioStreamFrames) m_pendingFrom = -1;
            else rewriteFrom(m_pendingFrom, silent, "fill", true);
        }

        if (live) prefetch();

        uint32_t buffered = 0;
        if (m_output->GetBufferedAudioSampleFrameCount(&buffered) != S_OK) return E_FAIL;
        // Under the committed window: see rewriteFrom. In a preroll, no deeper than the preroll's own depth (§10.25 item 2).
        const int32_t targetFrames = preroll ? std::min((int32_t)kRunsDepthFrames, m_prerollTargetFrames) : (int32_t)kRunsDepthFrames;
        if ((int32_t)buffered >= targetFrames) {
            if (preroll) endAudioPrerollIfNeeded();
            // Diagnostic (§10.22, verification): a queue that stays at or above the depth for over a second of stream time means the
            // card is not consuming it.
            BMDTimeValue hnow = 0; double hspeed = 0;
            m_output->GetScheduledStreamTime((BMDTimeScale)m_audio.sampleRate, &hnow, &hspeed);
            if (m_holdSince < 0) m_holdSince = (int64_t)hnow;
            else if (!m_holdLogged && (int64_t)hnow - m_holdSince > (int64_t)m_audio.sampleRate) {
                m_holdLogged = true;
                fprintf(stdout, "[SDI-AUDIO] !! holding over 1 s: buffered %u, now %lld (speed %.3f), queue end %lld, preroll %d, playback started %d\n",
                        buffered, (long long)hnow, hspeed, (long long)m_audioStreamFrames, (int)preroll, (int)m_playbackStarted.load());
                fflush(stdout);
            }
            return S_OK;
        }
        m_holdSince = -1; m_holdLogged = false;
        const int32_t want = std::min(targetFrames - (int32_t)buffered, m_maxCallbackFrames);
        if (want <= 0) return S_OK;
        int64_t pcm = 0, missing = 0, firstMissing = INT64_MAX;
        int32_t *dst = m_outScratch.data();
        const int64_t s = m_audioStreamFrames;
        fillDesired(s, want, silent, dst, pcm, missing, &firstMissing);
        if (firstMissing != INT64_MAX && m_pendingFrom < 0) m_pendingFrom = firstMissing;
        remember(s, want, dst);
        const uint32_t written = scheduleFrames(dst, want);
        if (missing > 0) { m_runMissingFrames += missing; m_underruns++; }
        m_pcmFramesScheduled += std::min<int64_t>(written, pcm);
        m_silenceFramesScheduled += written - std::min<int64_t>(written, pcm);
#ifdef DEBUG
        if (kAudioCorrLog && pcm > 0)
            fprintf(stdout, "[AUDIO-CORR] s=%lld n=%u got=%lld c=%d k=c e=%+.3f cur=%.6f\n", (long long)s, written, (long long)pcm, correction,
                    m_errEma / rate * 1000.0, (double)(s + m_run.D) / rate);
#endif
        if (m_audioStreamFrames - m_lastAudioLogFrames >= (BMDTimeValue)m_audio.sampleRate) {
            m_lastAudioLogFrames = m_audioStreamFrames;
            fprintf(stdout, "[SDI-AUDIO] runs: %s, D %lld, buffered %u, latches %llu, run ends %llu, re-latches %llu, late edges %llu (%lld samples), "
                            "missing %lld samples, err %+.2f samples, gate %s\n",
                    m_runActive ? "in a run" : "between runs", (long long)m_run.D, buffered, (unsigned long long)m_latches, (unsigned long long)m_runEnds,
                    (unsigned long long)m_relatches, (unsigned long long)m_lateEdges, (long long)m_lateEdgeFrames, (long long)m_runMissingFrames,
                    std::isfinite(m_steerErr) ? m_steerErr : 0.0, silent ? "silent" : "open");
            fflush(stdout);
        }
        return S_OK;
    }

    // Audio callback: the handed frame's pts and the slot its source time counts from. false: none yet, or the renderer has none.
    bool handedFrame(double &pts, int64_t &idx) {
        os_unfair_lock_lock(&m_handedLock);
        pts = m_handedPts;
        idx = (m_handedLastIdx - m_handedFirstIdx) <= kAudioMaxRepeatSlots ? m_handedFirstIdx : m_handedLastIdx;
        os_unfair_lock_unlock(&m_handedLock);
        return std::isfinite(pts) && idx >= 0;
    }

    // A fresh frame (not a pooled one, which the card may still hold) filled with video black, or NULL. Made while
    // playback still runs; tagged in `showFinalBlack`.
    IDeckLinkMutableVideoFrame *makeBlackFrame() {
        IDeckLinkMutableVideoFrame *f = NULL;
        if (m_output->CreateVideoFrame(m_width, m_height, m_rowBytes, bmdFormat10BitYUV, bmdFrameFlagDefault, &f) != S_OK || f == NULL)
            return NULL;
        IDeckLinkVideoBuffer *buffer = NULL;
        void *bytes = NULL;
        bool filled = false;
        if (f->QueryInterface(IID_IDeckLinkVideoBuffer, (void **)&buffer) == S_OK && buffer != NULL) {
            if (buffer->StartAccess(bmdBufferAccessWrite) == S_OK) {
                if (buffer->GetBytes(&bytes) == S_OK && bytes != NULL) {
                    FillVideoBlackV210((uint8_t *)bytes, m_rowBytes, m_height);
                    filled = true;
                }
                buffer->EndAccess(bmdBufferAccessWrite);
            }
            buffer->Release();
        }
        if (!filled) { f->Release(); return NULL; }
        return f;
    }

    // Show `black` as the output's last frame, tagged SDR, and hold it two frame durations so it reaches the wire before
    // the output is disabled. Logs the result and what the whole black step added to the stop (from `t0`, its start).
    void showFinalBlack(IDeckLinkMutableVideoFrame *black, std::chrono::steady_clock::time_point t0) {
        using Clock = std::chrono::steady_clock;
        // `DisplayVideoFrameSync` is refused during scheduled playback; the stop above is immediate, but wait for the
        // driver to say so (bounded: at most 100 ms).
        bool running = true;
        for (int i = 0; i < 100 && m_output->IsScheduledPlaybackRunning(&running) == S_OK && running; i++) usleep(1000);
        tagFrame(black, -1, kSDR709Signal);
        const HRESULT hr = m_output->DisplayVideoFrameSync(black);
        const double frameSeconds = (double)m_frameDuration / (double)m_timeScale;
        if (hr == S_OK) usleep((useconds_t)(2.0 * frameSeconds * 1e6));
        black->Release();
        const double ms = std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
        fprintf(stdout, "DeckLink: final black frame (Rec.709 · EOTF 0 · HDR flag clear) — DisplayVideoFrameSync → 0x%08X%s; "
                        "held 2 frames (%.1f ms); the black step added %.1f ms to the stop\n",
                (unsigned)hr, hr == S_OK ? "" : " ⚠️ not shown", 2.0 * frameSeconds * 1000.0, ms);
        fflush(stdout);
    }

    // Colour S7: tag the frame with the signal its picture was rendered under (`m_signal`, set by `fillFrame`). The
    // colorspace and the EOTF go on every frame, as Blackmagic's SignalGenHDR does. PQ also sets
    // `bmdFrameContainsHDRMetadata` and the static metadata, which only HDMI's InfoFrame carries (D6: SDI's VPID has
    // colorimetry and transfer only). HLG and SDR clear the flag (D3). The S7-0 probe found that a pooled frame KEEPS
    // its static values after the flag is cleared and that no call unsets them, so the flag is what says "none".
    // `frameIndex` -1 is the final black frame of an ended output, which is not scheduled.
    void tagFrame(IDeckLinkMutableVideoFrame *frame, int64_t frameIndex, const DeckLinkOutputSignal &s) {
        const BMDFrameFlags flags = frame->GetFlags();
        frame->SetFlags(s.hasStaticMetadata ? (flags | bmdFrameContainsHDRMetadata) : (flags & ~bmdFrameContainsHDRMetadata));
        IDeckLinkVideoFrameMutableMetadataExtensions *meta = NULL;
        if (frame->QueryInterface(IID_IDeckLinkVideoFrameMutableMetadataExtensions, (void **)&meta) != S_OK || meta == NULL) return;
        HRESULT worst = S_OK;
        auto note = [&worst](HRESULT h) { if (h != S_OK) worst = h; };
        note(meta->SetInt(bmdDeckLinkFrameMetadataColorspace, s.rec2020 ? bmdColorspaceRec2020 : bmdColorspaceRec709));
        note(meta->SetInt(bmdDeckLinkFrameMetadataHDRElectroOpticalTransferFunc, s.eotf));
        if (s.hasStaticMetadata) {
            note(meta->SetFloat(bmdDeckLinkFrameMetadataHDRDisplayPrimariesRedX, s.redX));
            note(meta->SetFloat(bmdDeckLinkFrameMetadataHDRDisplayPrimariesRedY, s.redY));
            note(meta->SetFloat(bmdDeckLinkFrameMetadataHDRDisplayPrimariesGreenX, s.greenX));
            note(meta->SetFloat(bmdDeckLinkFrameMetadataHDRDisplayPrimariesGreenY, s.greenY));
            note(meta->SetFloat(bmdDeckLinkFrameMetadataHDRDisplayPrimariesBlueX, s.blueX));
            note(meta->SetFloat(bmdDeckLinkFrameMetadataHDRDisplayPrimariesBlueY, s.blueY));
            note(meta->SetFloat(bmdDeckLinkFrameMetadataHDRWhitePointX, s.whiteX));
            note(meta->SetFloat(bmdDeckLinkFrameMetadataHDRWhitePointY, s.whiteY));
            note(meta->SetFloat(bmdDeckLinkFrameMetadataHDRMaxDisplayMasteringLuminance, s.maxMasteringLuminance));
            note(meta->SetFloat(bmdDeckLinkFrameMetadataHDRMinDisplayMasteringLuminance, s.minMasteringLuminance));
            note(meta->SetFloat(bmdDeckLinkFrameMetadataHDRMaximumContentLightLevel, s.maxCLL));
            note(meta->SetFloat(bmdDeckLinkFrameMetadataHDRMaximumFrameAverageLightLevel, s.maxFALL));
        }
        // Once per change, and on the first frame: the scheduled-frame index it starts at, and what the frame now
        // holds, read back through the same interface. That is what Manifold handed the driver, not what reached the
        // wire. Cheap: a change is rare, and this runs on that frame only.
        const bool changed = !m_loggedSignal || !SameSignal(s, m_lastLoggedSignal) || worst != S_OK;
        if (changed) {
            m_loggedSignal = true; m_lastLoggedSignal = s;
            int64_t cs = 0, eotf = -1;
            meta->GetInt(bmdDeckLinkFrameMetadataColorspace, &cs);
            meta->GetInt(bmdDeckLinkFrameMetadataHDRElectroOpticalTransferFunc, &eotf);
            char extra[512] = "";
            if (frame->GetFlags() & bmdFrameContainsHDRMetadata) {
                double v[12] = {0};
                const BMDDeckLinkFrameMetadataID ids[12] = {
                    bmdDeckLinkFrameMetadataHDRDisplayPrimariesRedX, bmdDeckLinkFrameMetadataHDRDisplayPrimariesRedY,
                    bmdDeckLinkFrameMetadataHDRDisplayPrimariesGreenX, bmdDeckLinkFrameMetadataHDRDisplayPrimariesGreenY,
                    bmdDeckLinkFrameMetadataHDRDisplayPrimariesBlueX, bmdDeckLinkFrameMetadataHDRDisplayPrimariesBlueY,
                    bmdDeckLinkFrameMetadataHDRWhitePointX, bmdDeckLinkFrameMetadataHDRWhitePointY,
                    bmdDeckLinkFrameMetadataHDRMaxDisplayMasteringLuminance, bmdDeckLinkFrameMetadataHDRMinDisplayMasteringLuminance,
                    bmdDeckLinkFrameMetadataHDRMaximumContentLightLevel, bmdDeckLinkFrameMetadataHDRMaximumFrameAverageLightLevel };
                for (int i = 0; i < 12; i++) meta->GetFloat(ids[i], &v[i]);
                snprintf(extra, sizeof extra, " · HDR flag set · R %.5f,%.5f G %.5f,%.5f B %.5f,%.5f W %.5f,%.5f · "
                         "max %.4f min %.5f cd/m2 · MaxCLL %.0f MaxFALL %.0f",
                         v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9], v[10], v[11]);
            } else {
                snprintf(extra, sizeof extra, " · HDR flag clear");
            }
            char which[48];
            if (frameIndex < 0) snprintf(which, sizeof which, "the final black frame");
            else snprintf(which, sizeof which, "scheduled frame #%lld", (long long)frameIndex);
            fprintf(stdout, "[DeckLink] signal on %s: read-back colorspace %s · EOTF %lld%s%s\n",
                    which, cs == bmdColorspaceRec2020 ? "Rec.2020" : (cs == bmdColorspaceRec709 ? "Rec.709" : "other"),
                    (long long)eotf, extra, worst == S_OK ? "" : " · ⚠️ a Set call failed");
            if (worst != S_OK) fprintf(stdout, "[DeckLink] ⚠️ metadata Set returned 0x%08X on frame #%lld\n", (unsigned)worst, (long long)frameIndex);
            fflush(stdout);
        }
        meta->Release();
    }

    std::atomic<ULONG> m_refCount;
    IDeckLinkOutput *m_output;
    BMDDisplayMode m_displayMode;   // the display mode this player enables/schedules (D4a: from the file)
    int32_t m_width, m_height, m_rowBytes;
    BMDTimeValue m_frameDuration;
    BMDTimeScale m_timeScale;
    FrameFillFn m_fill;
    DeckLinkCardFrameBlock m_cardFrame = nil;
    DeckLinkSilentStartBlock m_silentStart = nil;   // §10.25: a silent start goes up to the service, which restarts the output
    bool m_outputRestart = false;                   // this start is a silent-start recovery's: it is not recovered again
    std::vector<IDeckLinkMutableVideoFrame *> m_pool;
    std::atomic<bool> m_running;
    std::atomic<int64_t> m_nextIndex;
    std::atomic<uint64_t> m_completed, m_late, m_dropped, m_flushed;
    DeckLinkOutputSignal m_signal;           // the signal in force: the last picture's, else the start's (S7 D5)
    DeckLinkOutputSignal m_lastLoggedSignal = {};
    bool m_loggedSignal = false;

    // --- D4b-2 audio state ---
    // Written on the START thread before SetAudioCallback, then touched ONLY on the SDK's (serial)
    // audio callback thread — hence no locks. m_prerollingAudio is the exception: the start thread and
    // the callback thread both race to close the preroll window, so it is atomic.
    AudioSource m_audio;
    bool m_audioEnabled = false;
    std::atomic<bool> m_prerollingAudio{false};
    int32_t m_maxCallbackFrames = 0;
    std::vector<int32_t> m_srcScratch;      // preallocated: ring layout (source channels)
    std::vector<int32_t> m_outScratch;      // preallocated: wire layout (padded channels)
    BMDTimeValue m_audioStreamFrames = 0;   // audio streamTime, in sample frames (timeScale = sampleRate)
    // Stage 1c (§10.22). The slot ring: written by fills under m_handedLock, read in order by the audio callback.
    static const int kSlotRing = 64;
    Slot m_slots[kSlotRing];
    uint64_t m_slotWrites = 0, m_slotReads = 0;
    uint64_t m_lastHandSeq = 0;                       // fill thread only
    std::atomic<bool> m_byTime{false};
    std::atomic<bool> m_playbackStarted{false};
    std::atomic<uint64_t> m_audioCallbacks{0};   // every RenderAudioSamples call (diagnostic)
    // Output start and stop (§10.24). The callback try-locks this; the start holds it across EndAudioPreroll and StartScheduledPlayback.
    std::recursive_mutex m_audioCbMutex;
    uint64_t m_audioCbSkipped = 0;                // audio thread: callbacks skipped while the start held the lock
    StartCheck m_sc;                              // armed by startPlayback, then audio thread only
    int64_t m_audioOrigin = 0;                    // the stream position of the first audio scheduled (0; 10 s under the stall test)
    bool m_legacyStart = false, m_recoverStart = true;   // DEBUG test switches; production: SDK order, recovery on
    bool m_prerollVideoOnly = false;              // §10.25 item 2: preroll the video preroll's frames' audio, not 200 ms. DEBUG
                                                  // switch only: not kept (rs15-5994-pv: silent starts 1 of 102, unchanged; the
                                                  // first picture frame held 2–4 extra slots at 69 of 101 starts, 0 at 200 ms)
    int32_t m_prerollTargetFrames = 9600;         // set by beginAudioPreroll
    int64_t m_faultGap = 0;                       // DEBUG test switch
    std::atomic<bool> m_stoppedSignal{false};     // ScheduledPlaybackHasStopped seen
    uint64_t m_appendedEdges = 0, m_cadRederives = 0;   // §10.24 items 5 and 2
    uint64_t m_audioCallbacksSeen = 0;            // video thread: the count at the last check
    int64_t m_holdSince = -1; bool m_holdLogged = false;   // audio thread: the runs path holding at depth
    // Runs: audio callback only.
    Run m_run, m_prev;
    bool m_runsMode = false, m_runActive = false, m_wasSilent = true;
    double m_prevSlotPts = NAN; int64_t m_prevSlotIdx = -1;
    int64_t m_gateOpenAt = -1;
    double m_steerErr = NAN;                          // gate off: the exact error, samples (+: the picture is ahead of the sound)
    static const int64_t kHistFrames = 65536;         // what was scheduled at each stream position, for the edges' rewrite
    static const int64_t kEdgeGuardFrames = 48;       // an edge rewrites no nearer than 1 ms after the card's position (C0, C0b: 1 ms lands)
    static const int64_t kRunsDepthFrames = 3840;     // a file's queue: 80 ms, under the committed window (4715–5976 measured, C0)
    static const int64_t kRunsCommittedFrames = 4400; // a queue at most this deep is all committed: a latch waits for it
    uint64_t m_deepEdges = 0, m_timedEnds = 0;
    static const int kGateSlots = 8;                  // slots of gate silence with the picture on the line before the run ends
    int m_gateSlots = 0;
    static const int64_t kPreFrames = 16384, kPrefetchFrames = 6400;   // the prefetch ring; how far past the queue it reads (133 ms)
    std::vector<int32_t> m_pre; std::vector<int64_t> m_preKey; std::vector<uint64_t> m_preRun;
    int64_t m_preTo = 0; uint64_t m_runSerial = 0;
    uint64_t m_provHolds = 0, m_provRederives = 0;   // §10.25 item 4: provisional latches settled by a held first frame, or by the next frame
    uint64_t m_cadRuns = 0, m_cadGridFixes = 0, m_envMisses = 0, m_fineStarts = 0;   // C6 and the seek's fine search (§10.23)
    double m_envWorst = 0; int64_t m_fineRecovered = 0;
    int64_t m_pendingFrom = -1;                       // the first queued position scheduled as zeros for sound not decoded yet
    int64_t m_filledLate = 0;                         // samples written in later that way
    std::vector<int32_t> m_hist;
    uint64_t m_latches = 0, m_runEnds = 0, m_relatches = 0, m_lateEdges = 0;
    int64_t m_lateEdgeFrames = 0, m_runMissingFrames = 0;
    // The anchor's frame (noteHandedFrame / handedFrame): written by fills, read by the audio callback, under m_handedLock.
    os_unfair_lock m_handedLock = OS_UNFAIR_LOCK_INIT;
    double m_handedPts = NAN;
    int64_t m_handedFirstIdx = -1, m_handedLastIdx = -1;
    double m_cursorSeconds = 0.0;           // SOURCE time of the next sample frame to schedule
    bool m_cursorAnchored = false;          // false → snap to the video's source time next callback
    double m_errEma = 0.0;                  // smoothed (ideal − cursor), seconds
    uint64_t m_underruns = 0;               // ring had NOTHING at the cursor → silence + re-anchor (CALLBACKS)
    uint64_t m_underrunEvents = 0;          // runs of consecutive empty-ring callbacks (see noteUnderrunCallback)
    bool m_inUnderrunEvent = false;
    double m_eventStartSrcT = 0.0;
    uint32_t m_eventCallbacks = 0;
    uint64_t m_eventSilenceFrames = 0;
    uint64_t m_shortReads = 0;              // ring had SOME but not all → short schedule (no hole)
    uint64_t m_shortSchedules = 0;          // card accepted fewer frames than offered
    uint64_t m_resyncs = 0;                 // smoothed drift exceeded the band → cursor snapped
    // The scheduled-frame total splits in two. NOT DEBUG-gated: the stopped summary that prints the
    // split is itself unconditional, and a Release build reporting only a total would re-create the
    // exact ambiguity this split exists to remove. Two integer adds at 50 Hz cost nothing.
    uint64_t m_pcmFramesScheduled = 0;      // accepted frames that came from the ring (REAL audio)
    uint64_t m_silenceFramesScheduled = 0;  // accepted frames of digital silence (gate / no anchor /
                                            // underrun / critical-depth tail pad)
    BMDTimeValue m_lastAudioLogFrames = 0;
    BMDTimeValue m_lastUnderrunLogFrames = 0;
#ifdef DEBUG
    uint64_t m_branchLogCalls = 0;          // branch-trace invocations (burst counter, see logAudioBranch)
    BMDTimeValue m_lastBranchLogFrames = 0;
#endif

public:
    uint64_t audioUnderrunCount() const { return m_underruns; }
    uint64_t audioUnderrunEventCount() const { return m_underrunEvents; }
    uint64_t audioShortReadCount() const { return m_shortReads; }
    uint64_t audioResyncCount()   const { return m_resyncs; }
    uint64_t audioShortScheduleCount() const { return m_shortSchedules; }
    BMDTimeValue audioFramesScheduled() const { return m_audioStreamFrames; }
    uint64_t audioPcmFramesScheduled()     const { return m_pcmFramesScheduled; }
    uint64_t audioSilenceFramesScheduled() const { return m_silenceFramesScheduled; }
};

#pragma mark - D4a: display-mode selection (video cadence from the file's resolution + rate)

// Map an output raster + a broadcast rate to the matching PROGRESSIVE BMDDisplayMode. The rate is matched by pure
// NEAREST-MATCH (minimum |Δfps|) against the card's 15 progressive rates up to 120 (`SDIStandardRate.all`, 8 until
// the SDI scaling follow-ups) — NO ranges, NO boundaries, NO seams, so
// no input can be trapped on a bucket edge. The fractional NTSC rates use their EXACT n/1001 value
// (24000/1001 = 23.976…, 30000/1001 = 29.970…, 60000/1001 = 59.940…), so a 29.970 source lands ~0 from
// the 29.97 row and ~0.03 from the 30 row → p2997, never p30 and never a fallback. Every rate resolves
// to a real, card-supported progressive mode (all 15 are supported on device 0). Actual timing is read back off the
// resolved mode.
// Interlaced I2 (docs/INTERLACED_FINDINGS.md §2, §8): `interlaced` with 1920×1080 at the FRAME rate 25 / 29.97 / 30
// selects 1080i50 / 1080i59.94 / 1080i60 — the interlaced modes, never PsF. The decode path delivers woven frames
// untouched, and the SDK schedules an interlaced mode one woven frame per frame period (1001/30000 for 1080i59.94),
// so nothing else in the output changes. Any other rate or raster with `interlaced` → bmdModeUnknown.
// SDI scaling (§6.11): the raster is now any of the five the selector chooses from (`SDIOutputMode`, ColorimetryModel):
// 1280×720 (50 / 59.94 / 60 only), 1920×1080, 2048×1080 (2K DCI), 3840×2160, 4096×2160 (4K DCI). Unknown raster, or
// 720p at a rate it does not offer → bmdModeUnknown, and the start falls back to 2160p23.98 as before. Never 8K.
static BMDDisplayMode BMDModeForRasterRate(int32_t width, int32_t height, double rate, bool interlaced) {
    if (interlaced) {
        if (width != 1920 || height != 1080) return bmdModeUnknown;
        struct IRow { double rate; BMDDisplayMode mode; };
        static const IRow irows[] = { {25.0, bmdModeHD1080i50}, {30000.0 / 1001.0, bmdModeHD1080i5994}, {30.0, bmdModeHD1080i6000} };
        for (const IRow &r : irows) if (fabs(rate - r.rate) <= r.rate * 0.001) return r.mode;
        return bmdModeUnknown;
    }
    struct Row { double rate; BMDDisplayMode p720; BMDDisplayMode hd; BMDDisplayMode dci2k; BMDDisplayMode uhd; BMDDisplayMode dci4k; };
    static const Row rows[] = {
        {24000.0 / 1001.0, bmdModeUnknown,    bmdModeHD1080p2398, bmdMode2kDCI2398, bmdMode4K2160p2398, bmdMode4kDCI2398},   // 23.976…
        {24.0,             bmdModeUnknown,    bmdModeHD1080p24,   bmdMode2kDCI24,   bmdMode4K2160p24,   bmdMode4kDCI24},
        {25.0,             bmdModeUnknown,    bmdModeHD1080p25,   bmdMode2kDCI25,   bmdMode4K2160p25,   bmdMode4kDCI25},
        {30000.0 / 1001.0, bmdModeUnknown,    bmdModeHD1080p2997, bmdMode2kDCI2997, bmdMode4K2160p2997, bmdMode4kDCI2997},   // 29.970…
        {30.0,             bmdModeUnknown,    bmdModeHD1080p30,   bmdMode2kDCI30,   bmdMode4K2160p30,   bmdMode4kDCI30},
        {48000.0 / 1001.0, bmdModeUnknown,    bmdModeHD1080p4795, bmdMode2kDCI4795, bmdMode4K2160p4795, bmdMode4kDCI4795},   // 47.952…
        {48.0,             bmdModeUnknown,    bmdModeHD1080p48,   bmdMode2kDCI48,   bmdMode4K2160p48,   bmdMode4kDCI48},
        {50.0,             bmdModeHD720p50,   bmdModeHD1080p50,   bmdMode2kDCI50,   bmdMode4K2160p50,   bmdMode4kDCI50},
        {60000.0 / 1001.0, bmdModeHD720p5994, bmdModeHD1080p5994, bmdMode2kDCI5994, bmdMode4K2160p5994, bmdMode4kDCI5994},   // 59.940…
        {60.0,             bmdModeHD720p60,   bmdModeHD1080p6000, bmdMode2kDCI60,   bmdMode4K2160p60,   bmdMode4kDCI60},      // N.B. 1080p60 is bmdModeHD1080p6000
        // SDI scaling follow-up F2: the high rates, which the card offers at every raster but 720p (SDK probe, 2026-10-23).
        {96000.0 / 1001.0, bmdModeUnknown,    bmdModeHD1080p9590, bmdMode2kDCI9590, bmdMode4K2160p9590, bmdMode4kDCI9590},   // 95.904…
        {96.0,             bmdModeUnknown,    bmdModeHD1080p96,   bmdMode2kDCI96,   bmdMode4K2160p96,   bmdMode4kDCI96},
        {100.0,            bmdModeUnknown,    bmdModeHD1080p100,  bmdMode2kDCI100,  bmdMode4K2160p100,  bmdMode4kDCI100},
        {120000.0 / 1001.0, bmdModeUnknown,   bmdModeHD1080p11988, bmdMode2kDCI11988, bmdMode4K2160p11988, bmdMode4kDCI11988}, // 119.880…
        {120.0,            bmdModeUnknown,    bmdModeHD1080p120,  bmdMode2kDCI120,  bmdMode4K2160p120,  bmdMode4kDCI120},
    };
    double best = 1e9; const Row *row = &rows[0];
    for (const Row &r : rows) {
        const double d = fabs(rate - r.rate);
        if (d < best) { best = d; row = &r; }
    }
    if (width == 1280 && height == 720)  return row->p720;
    if (width == 1920 && height == 1080) return row->hd;
    if (width == 2048 && height == 1080) return row->dci2k;
    if (width == 3840 && height == 2160) return row->uhd;
    if (width == 4096 && height == 2160) return row->dci4k;
    return bmdModeUnknown;
}

// Short human label for a resolved mode, e.g. "2160p23.98" / "1080p25" / "720p59.94" / "2K DCI p23.98". The family
// comes from the raster; the rate token is snapped to the standard broadcast strings so 24000/1001
// reads "23.98" (not "23.976") and 30000/1001 reads "29.97".
// A BMDDisplayMode as its four characters ('Hp25'), for the refusal log; "none" for bmdModeUnknown or a non-printable
// value.
static NSString *FourCCString(BMDDisplayMode m) {
    if (m == bmdModeUnknown) return @"none";
    char c[5] = { (char)((m >> 24) & 0xFF), (char)((m >> 16) & 0xFF), (char)((m >> 8) & 0xFF), (char)(m & 0xFF), 0 };
    for (int i = 0; i < 4; i++) if (c[i] < 32 || c[i] > 126) return [NSString stringWithFormat:@"0x%08X", (unsigned)m];
    return [NSString stringWithFormat:@"'%s'", c];
}

// I2: the scan comes from the mode's own field dominance (`GetFieldDominance`), so an interlaced mode reads "1080i" and
// its token is the FIELD rate ("1080i59.94" for 1001/30000), as Blackmagic and `SDIOutputMode.label` name it.
static NSString *ModeNameForResolved(int32_t width, int32_t height, BMDTimeValue frameDuration, BMDTimeScale timeScale,
                                     BMDFieldDominance dominance) {
    const bool fields = dominance == bmdLowerFieldFirst || dominance == bmdUpperFieldFirst;
    // The same family names as `SDIModeFamily` (ColorimetryModel), so the label the card settles on is the selector's.
    const char *fam = fields ? "1080i"
                    : (width == 1280 && height == 720) ? "720p"
                    : (width == 2048 && height == 1080) ? "2K DCI p"
                    : (width == 4096 && height == 2160) ? "4K DCI p"
                    : (height >= 1620) ? "2160p" : "1080p";
    double r = (frameDuration > 0) ? (double)timeScale / (double)frameDuration : 0.0;
    if (fields) r *= 2;
    struct { double rate; const char *tok; } toks[] = {
        {24000.0 / 1001.0,"23.98"}, {24,"24"}, {25,"25"}, {30000.0 / 1001.0,"29.97"},
        {30,"30"}, {48000.0 / 1001.0,"47.95"}, {48,"48"}, {50,"50"}, {60000.0 / 1001.0,"59.94"}, {60,"60"},
        {96000.0 / 1001.0,"95.90"}, {96,"96"}, {100,"100"}, {120000.0 / 1001.0,"119.88"}, {120,"120"}
    };
    // Nearest-match (same principle as the mode selector) against EXACT n/1001 rates: the resolved
    // mode's true rate (e.g. 30000/1001 = 29.970) lands ~0 from its own token and ~0.03 from the
    // integer neighbour, so 24000/1001 reads "23.98" and 24000/1000 reads "24" — no collision.
    NSString *rateStr = [NSString stringWithFormat:@"%.2f", r];
    double best = 1e9;
    for (auto &t : toks) { double d = fabs(r - t.rate); if (d < best) { best = d; rateStr = @(t.tok); } }
    return [NSString stringWithFormat:@"%s%@", fam, rateStr];
}

#pragma mark - Bridge

// GetModelName / GetDisplayName return a NEWLY-CREATED CFStringRef via out-param on macOS (the
// SDK's dl_string maps to CFStringRef here). The caller owns it, so __bridge_transfer hands the
// +1 to ARC (no leak). Nil-safe.
static NSString *NSStringTakeDeckLink(CFStringRef s) {
    if (s == NULL) { return @""; }
    return (__bridge_transfer NSString *)s;
}

#pragma mark - Desktop Video version floor (ONE definition, every caller reads it from here)

// The output floor: Desktop Video >= 16.0. Defined once so the number cannot drift between the
// startup report, the Settings row, the toolbar gate and the output path's own abort — before this
// existed, only the output path knew it, which is why a below-floor driver read as "not reachable"
// everywhere else.
//
// ── ⚠️ WHAT 16.0 IS, AND WHAT IT IS NOT ────────────────────────────────────────────────────
//
// 16.0 IS THE SDK VERSION THIS TARGET COMPILES AGAINST, and therefore the newest interface
// generation this binary knows how to ask for. IT IS NOT A MEASURED LOWER BOUND. Nobody has tested
// this build against a 16.0 driver and found it to be the last one that works; the claim is
// narrower and provable from the headers:
//
//   `IID_IDeckLinkOutput` is versioned, and we link the CURRENT one. DeckLinkAPI.h (SDK 16.0) also
//   declares IID_IDeckLinkOutput_v10_11, _v11_4, _v14_2_1 and _v15_3_1 — the interface as it stood
//   in each of those releases. The newest SUPERSEDED entry is _v15_3_1, so the unversioned
//   5F227C95-39D7-46C7-8B7D-9C81795FBBE4 we query is the post-15.3.1 revision. A driver older than
//   16.0 does not vend it and answers E_NOINTERFACE, from perfectly healthy hardware.
//
// So the floor is "the oldest driver whose IDeckLinkOutput we are compiled to ask for", which is a
// statement about this source tree, not about Blackmagic's hardware or about anyone's machine.
//
// ── WHY THE PREVIOUS FLOOR (14.3) WAS WORSE THAN NO FLOOR ──────────────────────────────────
//
// It was reasoned from the SDK changelog (the IOSurface/zero-copy work) rather than from the IIDs,
// and nothing in this repo ever recorded a test against a 14.3–15.x driver. It READ as measured. The
// result was a floor that admitted drivers this binary cannot talk to: a 14.3 machine was waved
// through as "floor: 14.3 — met", every device was then silently rejected by the QueryInterface
// above, and the user was told "no device detected" about hardware sitting in the slot. Two wrong
// answers in a row, each one confidently phrased.
//
// ⚠️ IF YOU RAISE THE SDK, RAISE THIS WITH IT. The two numbers are the same fact. A new SDK whose
// IDeckLinkOutput has been revised again will reject every older driver in exactly the same way,
// and the only thing standing between that and another silent misdiagnosis is this constant moving
// at the same time. The rejection counts reported by `enumerateDevices` are the backstop that makes
// the failure legible if it does not.
static const int kDeckLinkFloorMajor = 16;
static const int kDeckLinkFloorMinor = 0;

// Read the INSTALLED driver's runtime API version (not the SDK header we compiled against).
// Encoding is 0xMMmmpp00 (see the SDK's DeviceList sample).
//
// HONESTY NOTE — this is the SAME call the output path makes, and it needs NEITHER a card NOR an
// output attempt: CreateDeckLinkAPIInformationInstance() is vended by the loaded Desktop Video
// framework itself, so it answers at startup exactly as it answers at output time. Nothing here is
// inferred or probed indirectly. Returns NO only when the framework isn't loaded (driver absent) or
// the query itself fails — i.e. when we genuinely do not know the version. `outHR`, when given, gets GetInt's answer,
// or S_OK when there was no information object to ask.
static BOOL DeckLinkReadInstalledVersion(int *outMajor, int *outMinor, int *outPoint, HRESULT *outHR = NULL) {
    if (outHR) { *outHR = S_OK; }
    IDeckLinkAPIInformation *apiInfo = CreateDeckLinkAPIInformationInstance();
    if (apiInfo == NULL) { return NO; }
    int64_t apiVersion = 0;
    HRESULT hr = apiInfo->GetInt(BMDDeckLinkAPIVersion, &apiVersion);
    apiInfo->Release();
    if (outHR) { *outHR = hr; }
    if (hr != S_OK) { return NO; }
    if (outMajor) { *outMajor = (int)((apiVersion & 0xFF000000) >> 24); }
    if (outMinor) { *outMinor = (int)((apiVersion & 0x00FF0000) >> 16); }
    if (outPoint) { *outPoint = (int)((apiVersion & 0x0000FF00) >> 8);  }
    return YES;
}

static BOOL DeckLinkVersionMeetsFloor(int major, int minor) {
    if (major != kDeckLinkFloorMajor) { return major > kDeckLinkFloorMajor; }
    return minor >= kDeckLinkFloorMinor;
}

// Private: the shared start sequence parameterized by a C++ FrameFillFn (C++ type in the selector,
// so it can only live in the .mm). Public entry points wrap their fill and forward here.
@interface DeckLinkBridge ()
- (DeckLinkOutputResult *)startScheduledPlaybackWithFillFn:(FrameFillFn)fill
                                               deviceIndex:(NSInteger)deviceIndex
                                             initialSignal:(DeckLinkOutputSignal)initialSignal
                                               displayMode:(BMDDisplayMode)displayMode
                                               audioConfig:(DeckLinkAudioConfig *)audioConfig;
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
    return [self enumerateDevices].usable;
}

+ (DeckLinkEnumerationResult *)enumerateDevices {
    NSMutableArray<DeckLinkDeviceInfo *> *usable = [NSMutableArray array];
    NSMutableArray<DeckLinkRejectedDeviceInfo *> *rejected = [NSMutableArray array];
    NSInteger total = 0;

    // Plain C entry point on macOS (no COM initialization needed).
    IDeckLinkIterator *iterator = CreateDeckLinkIteratorInstance();
    if (iterator == NULL) {
        // Driver not installed / SDK runtime unavailable. A zero TOTAL, which is the honest answer:
        // we never got to look at any hardware.
        return [[DeckLinkEnumerationResult alloc] initWithTotalCount:0 usable:usable rejected:rejected];
    }

    IDeckLink *device = NULL;
    NSInteger index = 0;
    while (iterator->Next(&device) == S_OK) {
        total++;
        // Output-capable? A device that vends IDeckLinkOutput supports playback.
        //
        // ⚠️ A FAILURE HERE IS USUALLY A DRIVER VERSION, NOT A BROKEN CARD. `IID_IDeckLinkOutput` is
        // the interface as revised for the SDK we compile against, and Blackmagic revises it: the
        // 16.0 headers carry IID_IDeckLinkOutput_v10_11, _v11_4, _v14_2_1 and _v15_3_1 alongside the
        // current one. A driver older than our SDK vends one of the superseded IIDs and answers
        // E_NOINTERFACE to this call — from a card that is plugged in, powered, and fine. That is
        // why the HRESULT is CARRIED OUT of this loop instead of being tested and dropped.
        IDeckLinkOutput *output = NULL;
        HRESULT hr = device->QueryInterface(IID_IDeckLinkOutput, (void **)&output);

        // Asked on BOTH paths, and asked before the branch: `IDeckLink` has exactly two methods and
        // exactly one interface ID across every SDK generation (IID_IDeckLink C418FBDD; the 16.0
        // headers declare no `_vNN` variant of it), so the model name is reachable on a device whose
        // OUTPUT interface is not — which is precisely the device worth naming.
        CFStringRef modelName = NULL;
        device->GetModelName(&modelName);
        NSString *model = NSStringTakeDeckLink(modelName);

        if (hr == S_OK && output != NULL) {
            CFStringRef displayName = NULL;
            device->GetDisplayName(&displayName);

            DeckLinkDeviceInfo *info =
                [[DeckLinkDeviceInfo alloc] initWithIndex:index
                                                modelName:model
                                              displayName:NSStringTakeDeckLink(displayName)];
            [usable addObject:info];

            output->Release();   // balance the QueryInterface +1
        } else {
            [rejected addObject:[[DeckLinkRejectedDeviceInfo alloc] initWithIndex:index
                                                                       modelName:model
                                                                         hresult:(int32_t)hr]];
        }
        device->Release();       // balance the Next() +1
        device = NULL;
        index++;
    }

    iterator->Release();         // balance CreateDeckLinkIteratorInstance +1
    return [[DeckLinkEnumerationResult alloc] initWithTotalCount:total usable:usable rejected:rejected];
}

+ (BOOL)isDriverInstalled {
    // Additive, read-only — does NOT touch InitDeckLinkAPI or the enumeration path above.
    // CreateDeckLinkIteratorInstance triggers the same pthread_once framework load the enumeration
    // uses; a non-null iterator is equivalent to "Desktop Video framework present" (the iterator can
    // only be created once the CFBundle loaded). We read it this way rather than IsDeckLinkAPIPresent()
    // because that symbol isn't declared in any SDK header (only defined in DeckLinkAPIDispatch.cpp).
    IDeckLinkIterator *it = CreateDeckLinkIteratorInstance();
    if (it) { it->Release(); return YES; }
    return NO;
}

+ (NSString *)installedDriverVersion {
    int major = 0, minor = 0, point = 0;
    if (!DeckLinkReadInstalledVersion(&major, &minor, &point)) { return nil; }
    return [NSString stringWithFormat:@"%d.%d.%d", major, minor, point];
}

+ (BOOL)installedDriverMeetsOutputFloor {
    int major = 0, minor = 0, point = 0;
    if (!DeckLinkReadInstalledVersion(&major, &minor, &point)) { return NO; }
    return DeckLinkVersionMeetsFloor(major, minor);
}

+ (NSString *)requiredDriverVersion {
    return [NSString stringWithFormat:@"%d.%d", kDeckLinkFloorMajor, kDeckLinkFloorMinor];
}

#pragma mark - D2: first light (one synthetic frame, held on the output)

- (DeckLinkOutputResult *)startTestFrameOutputOnDevice0 {
    NSMutableArray<NSString *> *log = [NSMutableArray array];

    // Re-fire cleanly: tear down any previously-held output first.
    [self stopTestOutput];

    // (b) Version floor — the shared check (see DeckLinkReadInstalledVersion). The UI gates on the
    // same answer BEFORE the button is clickable, so reaching an abort here means the driver changed
    // under a running app; it stays as the last line of defence.
    {
        int major = 0, minor = 0, point = 0; HRESULT verHR = S_OK;
        if (!DeckLinkReadInstalledVersion(&major, &minor, &point, &verHR)) {
            [log addObject:[NSString stringWithFormat:@"version: DeckLink API information unavailable (driver not reachable; GetInt hr=0x%08X) — aborting",
                            (unsigned)verHR]];
            return [[DeckLinkOutputResult alloc] initFailureWithLog:log call:@"GetInt(BMDDeckLinkAPIVersion)" hresult:verHR];
        }
        NSString *verStr = [NSString stringWithFormat:@"%d.%d.%d", major, minor, point];
        if (!DeckLinkVersionMeetsFloor(major, minor)) {
            [log addObject:[NSString stringWithFormat:
                @"version floor: DeckLink output requires Desktop Video %@ or later; installed: %@ — aborting",
                [DeckLinkBridge requiredDriverVersion], verStr]];
            return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
        }
        [log addObject:[NSString stringWithFormat:@"version: Desktop Video %@ (>= %@ floor OK)",
                        verStr, [DeckLinkBridge requiredDriverVersion]]];
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
        [log addObject:[NSString stringWithFormat:@"device: index 0 has no IDeckLinkOutput (QueryInterface hr=0x%08X) — aborting", (unsigned)hr]];
        return [[DeckLinkOutputResult alloc] initFailureWithLog:log call:@"QueryInterface(IDeckLinkOutput)" hresult:hr];
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
        [log addObject:[NSString stringWithFormat:@"mode: 2160p23.98 / 8-bit YUV NOT supported on device 0 (DoesSupportVideoMode hr=0x%08X supported=%d) — aborting",
                        (unsigned)hr, supported ? 1 : 0]];
        output->Release();
        return [[DeckLinkOutputResult alloc] initFailureWithLog:log call:@"DoesSupportVideoMode" hresult:hr];
    }
    [log addObject:@"mode: 2160p23.98 / 8-bit YUV supported"];

    // (d) EnableVideoOutput.
    hr = output->EnableVideoOutput(bmdMode4K2160p2398, bmdVideoOutputFlagDefault);
    if (hr != S_OK) {
        [log addObject:[NSString stringWithFormat:@"enable: EnableVideoOutput failed (hr=0x%08X) — aborting", (unsigned)hr]];
        output->Release();
        return [[DeckLinkOutputResult alloc] initFailureWithLog:log call:@"EnableVideoOutput" hresult:hr];
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
        return [[DeckLinkOutputResult alloc] initFailureWithLog:log call:@"CreateVideoFrame" hresult:hr];
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
            [log addObject:[NSString stringWithFormat:@"fill: IDeckLinkVideoBuffer unavailable (QueryInterface hr=0x%08X) — aborting", (unsigned)hr]];
            frame->Release(); output->DisableVideoOutput(); output->Release();
            return [[DeckLinkOutputResult alloc] initFailureWithLog:log call:@"QueryInterface(IDeckLinkVideoBuffer)" hresult:hr];
        }
        hr = buffer->StartAccess(bmdBufferAccessWrite);
        if (hr != S_OK) {
            [log addObject:[NSString stringWithFormat:@"fill: StartAccess(write) failed (hr=0x%08X) — aborting", (unsigned)hr]];
            buffer->Release(); frame->Release(); output->DisableVideoOutput(); output->Release();
            return [[DeckLinkOutputResult alloc] initFailureWithLog:log call:@"StartAccess" hresult:hr];
        }
        void *bytes = NULL;
        hr = buffer->GetBytes(&bytes);
        if (hr != S_OK || bytes == NULL) {
            [log addObject:[NSString stringWithFormat:@"fill: GetBytes failed (hr=0x%08X) — aborting", (unsigned)hr]];
            buffer->EndAccess(bmdBufferAccessWrite); buffer->Release();
            frame->Release(); output->DisableVideoOutput(); output->Release();
            return [[DeckLinkOutputResult alloc] initFailureWithLog:log call:@"GetBytes" hresult:hr];
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
        return [[DeckLinkOutputResult alloc] initFailureWithLog:log call:@"DisplayVideoFrameSync" hresult:hr];
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
                                             initialSignal:(DeckLinkOutputSignal)initialSignal
                                               displayMode:(BMDDisplayMode)displayMode
                                               audioConfig:(DeckLinkAudioConfig *)audioConfig {
    NSMutableArray<NSString *> *log = [NSMutableArray array];

    // Re-fire cleanly.
    [self stopScheduledPlayback];

    // Version floor — same shared check as D2.
    {
        int major = 0, minor = 0, point = 0; HRESULT verHR = S_OK;
        if (!DeckLinkReadInstalledVersion(&major, &minor, &point, &verHR)) {
            [log addObject:[NSString stringWithFormat:@"version: DeckLink API information unavailable (GetInt hr=0x%08X) — aborting",
                            (unsigned)verHR]];
            return [[DeckLinkOutputResult alloc] initFailureWithLog:log call:@"GetInt(BMDDeckLinkAPIVersion)" hresult:verHR];
        }
        NSString *verStr = [NSString stringWithFormat:@"%d.%d.%d", major, minor, point];
        if (!DeckLinkVersionMeetsFloor(major, minor)) {
            [log addObject:[NSString stringWithFormat:
                @"version floor: DeckLink output requires Desktop Video %@ or later; installed: %@ — aborting",
                [DeckLinkBridge requiredDriverVersion], verStr]];
            return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
        }
        [log addObject:[NSString stringWithFormat:@"version: Desktop Video %@ (>= %@ floor OK)",
                        verStr, [DeckLinkBridge requiredDriverVersion]]];
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
#if DEBUG
    cardClockAdopt(target);
#endif
    target->Release();
    if (hr != S_OK || output == NULL) {
        [log addObject:[NSString stringWithFormat:@"device: index %ld has no IDeckLinkOutput (QueryInterface hr=0x%08X) — aborting",
                        (long)deviceIndex, (unsigned)hr]];
        return [[DeckLinkOutputResult alloc] initFailureWithLog:log call:@"QueryInterface(IDeckLinkOutput)" hresult:hr];
    }
    [log addObject:[NSString stringWithFormat:@"device: index %ld = \"%@\", IDeckLinkOutput acquired", (long)deviceIndex, name]];

    // SEAM (D4a): dimensions + frame rate come from the OUTPUT MODE object, driven by the requested
    // `displayMode` (derived from the file's resolution + rate). A different mode drives
    // width/height/rowBytes/timescale — the scheduling timing follows the resolved mode. If the exact
    // mode can't be resolved (unknown / not in this SDK), fall back to 2160p23.98 so output still runs.
    BMDDisplayMode wantMode = displayMode;
    IDeckLinkDisplayMode *mode = NULL;
    if (wantMode == bmdModeUnknown || output->GetDisplayMode(wantMode, &mode) != S_OK || mode == NULL) {
        if (mode) { mode->Release(); mode = NULL; }
        [log addObject:@"mode: requested display mode unresolved — falling back to 2160p23.98"];
        wantMode = bmdMode4K2160p2398;
        hr = output->GetDisplayMode(wantMode, &mode);
        if (hr != S_OK || mode == NULL) {
            [log addObject:[NSString stringWithFormat:
                @"mode: could not resolve fallback 2160p23.98 display mode (GetDisplayMode hr=0x%08X) — aborting", (unsigned)hr]];
            output->Release();
            return [[DeckLinkOutputResult alloc] initFailureWithLog:log call:@"GetDisplayMode" hresult:hr];
        }
    }
    const int32_t width  = (int32_t)mode->GetWidth();
    const int32_t height = (int32_t)mode->GetHeight();
    BMDTimeValue frameDuration = 0; BMDTimeScale timeScale = 0;
    mode->GetFrameRate(&frameDuration, &timeScale);
    const BMDFieldDominance dominance = mode->GetFieldDominance();
    mode->Release();
    NSString *modeName = ModeNameForResolved(width, height, frameDuration, timeScale, dominance);
    int32_t rowBytes = 0;
    output->RowBytesForPixelFormat(bmdFormat10BitYUV, width, &rowBytes);   // authoritative v210 stride (128-aligned)
    [log addObject:[NSString stringWithFormat:@"mode: %@ (%dx%d @ %lld/%lld duration/timescale, %s), v210 rowBytes=%d",
                    modeName, width, height, (long long)timeScale, (long long)frameDuration,
                    dominance == bmdUpperFieldFirst ? "interlaced, upper field first"
                    : dominance == bmdLowerFieldFirst ? "interlaced, lower field first"
                    : dominance == bmdProgressiveSegmentedFrame ? "PsF" : "progressive", rowBytes]];

    // Build the player (SEAM: fill source is pluggable — synthetic hue-walk for D3). The player
    // AddRefs the output; drop our local ref. `initialSignal` is what frames carry until the first picture brings
    // its own (colour S7, D5). The resolved `wantMode` drives EnableVideoOutput + DoesSupportVideoMode.
    DeckLinkScheduledPlayer *player =
        new DeckLinkScheduledPlayer(output, wantMode, width, height, rowBytes, frameDuration, timeScale, fill, initialSignal);
    player->setCardFrame(self.cardFrame);
    player->setSilentStart(self.silentStart, self.outputRestart);   // before enableAudio, which reads the start's test switches
    output->Release();
    [log addObject:[NSString stringWithFormat:@"tag: until the first picture — colorspace %@ · EOTF %d%@",
                    (initialSignal.rec2020 ? @"Rec. 2020" : @"Rec. 709"), (int)initialSignal.eotf,
                    initialSignal.hasStaticMetadata ? @" · HDR static metadata" : @""]];

    // A refusal is logged with the API's own answer and retried once after 100 ms before it is believed: the one
    // refusal seen (L4, 1080p25) came straight after a stop that does not wait for ScheduledPlaybackHasStopped.
    DeckLinkScheduledPlayer::ModeSupport support = player->checkModeSupport();
    NSString *forced = @"";
#ifdef DEBUG
    // Test hook (pre-ship removal, docs/BUGS.md): MANIFOLD_DECKLINK_REFUSE_MODE_ONCE=1 makes the first check of the
    // process read as refused, so the retry path can be run on a card that never refuses.
    static bool refusedOnce = false;
    const char *refuse = getenv("MANIFOLD_DECKLINK_REFUSE_MODE_ONCE");
    if (!refusedOnce && refuse && strcmp(refuse, "1") == 0) {
        refusedOnce = true; support.supported = false; forced = @" (forced by MANIFOLD_DECKLINK_REFUSE_MODE_ONCE)";
    }
#endif
    if (!support.ok()) {
        [log addObject:[NSString stringWithFormat:@"mode: %@ / v210 10-bit YUV refused — hr=0x%08X supported=%d actual=%@%@; retrying once in 100 ms",
                        modeName, (unsigned)support.hr, support.supported ? 1 : 0, FourCCString(support.actual), forced]];
        usleep(100000);
        support = player->checkModeSupport();
        [log addObject:[NSString stringWithFormat:@"mode: %@ / retry — hr=0x%08X supported=%d actual=%@",
                        modeName, (unsigned)support.hr, support.supported ? 1 : 0, FourCCString(support.actual)]];
    }
    if (!support.ok()) {
        [log addObject:[NSString stringWithFormat:@"mode: %@ / v210 10-bit YUV NOT supported (DoesSupportVideoMode hr=0x%08X supported=%d) — aborting",
                        modeName, (unsigned)support.hr, support.supported ? 1 : 0]];
        player->stop(); player->Release();
        return [[DeckLinkOutputResult alloc] initFailureWithLog:log call:@"DoesSupportVideoMode" hresult:support.hr];
    }
    [log addObject:[NSString stringWithFormat:@"mode: %@ / v210 10-bit YUV supported", modeName]];

    DeckLinkScheduledPlayer::CallResult step = player->enableOutput();
    NSString *forcedEnable = @"";
#ifdef DEBUG
    // Test hook (pre-ship removal, docs/BUGS.md): MANIFOLD_DECKLINK_ENABLE_HR=<hex> makes every EnableVideoOutput of the
    // process read as failed with that code, so the busy and the generic refusal can be run with no other app holding
    // the card. A real enable that succeeded is undone by the abort's player->stop(), as for any later failure.
    if (const char *forceHR = getenv("MANIFOLD_DECKLINK_ENABLE_HR")) {
        step.hr = (HRESULT)(uint32_t)strtoul(forceHR, NULL, 16);
        forcedEnable = @" (forced by MANIFOLD_DECKLINK_ENABLE_HR)";
    }
#endif
    if (!step.ok()) {
        [log addObject:[NSString stringWithFormat:@"enable: %s failed (hr=0x%08X)%@ — aborting", step.call, (unsigned)step.hr, forcedEnable]];
        player->stop(); player->Release();
        return [[DeckLinkOutputResult alloc] initFailureWithLog:log call:@(step.call) hresult:step.hr];
    }
    [log addObject:@"enable: video output enabled"];

    // D4b-2 (a): EnableAudioOutput — AFTER video is enabled, BEFORE the pool/preroll/start. The SDK
    // takes only 48 kHz (BMDAudioSampleRate has exactly one member), so a non-48k source is refused
    // upstream (DeckLinkService) rather than mis-signalled here. A nil config = video-only output.
    if (audioConfig != nil) {
        AudioSource src;
        src.sampleRate  = (uint32_t)llround(audioConfig.sampleRate);
        src.srcChannels = (uint32_t)audioConfig.sourceChannelCount;
        src.dlChannels  = (uint32_t)audioConfig.deckLinkChannelCount;
        src.trimSeconds = audioConfig.trimSeconds;
        DeckLinkAudioSourceTimeBlock timeBlock = [audioConfig.sourceTime copy];
        DeckLinkAudioSilentBlock silentBlock = [audioConfig.isSilent copy];
        DeckLinkAudioSilentBlock destinationBlock = [audioConfig.isDestinationSilent copy];
        DeckLinkAudioReadBlock readBlock = [audioConfig.read copy];
        src.sourceTime = [timeBlock]() -> double { return timeBlock(); };
        src.isSilent   = [silentBlock]() -> bool { return silentBlock() ? true : false; };
        src.isDestinationSilent = [destinationBlock]() -> bool { return destinationBlock() ? true : false; };
        src.read       = [readBlock](double t, int32_t n, int32_t *dst) -> int32_t { return readBlock(t, n, dst); };
        if (DeckLinkAudioHandedBlock handedBlock = [audioConfig.handed copy]) {
            src.handed = [handedBlock](double *pts, bool *timed, bool *byTime, uint64_t *seq, double *due, double *srcFrame) {
                BOOL t = NO, b = NO; handedBlock(pts, &t, &b, seq, due, srcFrame); *timed = t; *byTime = b;
            };
        }
        src.cardTimeline = audioConfig.cardTimeline;
        step = player->enableAudio(src);
        if (!step.ok()) {
            [log addObject:[NSString stringWithFormat:
                @"audio: EnableAudioOutput(%u Hz, 32-bit int, %u ch, timestamped) failed (hr=0x%08X) — aborting",
                src.sampleRate, src.dlChannels, (unsigned)step.hr]];
            player->stop(); player->Release();
            return [[DeckLinkOutputResult alloc] initFailureWithLog:log call:@(step.call) hresult:step.hr];
        }
        [log addObject:[NSString stringWithFormat:
            @"audio: enabled — %u Hz · 32-bit int · %u ch on the wire (source %u ch, %u padded silent) · "
            @"timestamped · trim %+.0f ms",
            src.sampleRate, src.dlChannels, src.srcChannels, src.dlChannels - src.srcChannels,
            src.trimSeconds * 1000.0]];
    } else {
        [log addObject:@"audio: none (no audio track / unsupported rate) — video-only output"];
    }

    const int poolSize = 4;
    step = player->createPool(poolSize);
    if (!step.ok()) {
        [log addObject:[NSString stringWithFormat:@"pool: %s failed (hr=0x%08X) — aborting", step.call, (unsigned)step.hr]];
        player->stop(); player->Release();
        return [[DeckLinkOutputResult alloc] initFailureWithLog:log call:@(step.call) hresult:step.hr];
    }
    [log addObject:[NSString stringWithFormat:@"pool: %d reusable frames created", poolSize]];

    player->beginRunning();   // set completion callback + arm
    [log addObject:@"callback: SetScheduledFrameCompletionCallback installed"];

    // D4b-2 (b)+(c): SetAudioCallback + BeginAudioPreroll BEFORE the video preroll, so RenderAudioSamples
    // fires DURING it and the card's audio buffer prefills to depth alongside the video frames — the two
    // streams reach StartScheduledPlayback equally deep, which is what makes their pipeline delays match.
    if (player->audioEnabled()) {
        player->beginAudioPreroll();
        [log addObject:@"audio: SetAudioCallback installed + BeginAudioPreroll (prefilling during video preroll)"];
    }

    step = player->preroll();
    if (!step.ok()) {
        [log addObject:[NSString stringWithFormat:@"preroll: %s failed (hr=0x%08X) — aborting", step.call, (unsigned)step.hr]];
        player->stop(); player->Release();
        return [[DeckLinkOutputResult alloc] initFailureWithLog:log call:@(step.call) hresult:step.hr];
    }
    [log addObject:[NSString stringWithFormat:@"preroll: %d frames scheduled (indices 0..%d)", poolSize, poolSize - 1]];

    // The audio preroll's end (§10.24): the manual's "when audio preroll is complete". The callback ends it itself the moment the
    // queue reaches its depth; wait for that (bounded), and end it here only if it never came. Until 2026-11-11 it was ended here
    // as soon as the video preroll was scheduled, whatever the audio had reached.
    if (player->audioEnabled()) {
        const auto pr = player->finishAudioPreroll();
        [log addObject:[NSString stringWithFormat:@"audio: EndAudioPreroll — %@ after %.1f ms, %u samples queued, %llu audio callbacks%@",
                        pr.byCallback ? @"preroll complete (ended by the callback)" : @"⚠️ preroll not complete, ended here",
                        pr.waitedMs, pr.buffered, (unsigned long long)pr.callbacks, player->legacyStart() ? @" [LEGACY start]" : @""]];
    }

    step = player->startPlayback();
    if (!step.ok()) {
        [log addObject:[NSString stringWithFormat:@"start: %s failed (hr=0x%08X) — aborting", step.call, (unsigned)step.hr]];
        player->stop(); player->Release();
        return [[DeckLinkOutputResult alloc] initFailureWithLog:log call:@(step.call) hresult:step.hr];
    }
#if DEBUG
    cardClockLogReference("start", output);
#endif
    [log addObject:[NSString stringWithFormat:@"start: StartScheduledPlayback(0, %lld, 1.0) OK — free-running at %@%@",
                    (long long)timeScale, modeName, player->audioEnabled() ? @" (video + SDI audio)" : @" (video only)"]];

    _player = player;   // held; callback keeps the pipeline full until -stopScheduledPlayback
    _activeFrameSeconds = (double)frameDuration / (double)timeScale;
    return [[DeckLinkOutputResult alloc] initWithSuccess:YES log:log activeModeName:modeName];
}

// Public: synthetic hue-walk on device 0 (D3 — debug/fallback). No source → tag Rec.709, 2160p23.98,
// and no audio (there is no source to serve).
- (DeckLinkOutputResult *)startScheduledPlaybackOnDevice0 {
    FrameFillFn fn = [](int64_t frameIndex, uint8_t *buffer, int32_t rowBytes, int32_t width, int32_t height,
                        DeckLinkOutputSignal *) -> bool {
        SyntheticHueWalkFill(frameIndex, buffer, rowBytes, width, height);
        return false;   // keeps the start's signal: SDR Rec.709
    };
    DeckLinkOutputSignal sdr709 = {};
    return [self startScheduledPlaybackWithFillFn:fn
                                      deviceIndex:0
                                    initialSignal:sdr709
                                      displayMode:bmdMode4K2160p2398
                                      audioConfig:nil];
}

// Public: REAL video (D-real) on a chosen device. Wrap the Obj-C fill block into the C++ FrameFillFn
// the scheduler expects; the std::function retains the (heap-copied) block for the player's lifetime.
// The block itself sources pixels (renderer.copyLatest…) and handles the neutral fallback — the
// scheduler stays source-agnostic. Each picture brings its own signal (colour S7, D1); `initialSignal` covers the
// frames before the first one.
- (DeckLinkOutputResult *)startScheduledPlaybackWithDeviceIndex:(NSInteger)deviceIndex
                                                          fill:(DeckLinkFillBlock)fill
                                                 initialSignal:(DeckLinkOutputSignal)initialSignal
                                                   outputWidth:(NSInteger)outputWidth
                                                  outputHeight:(NSInteger)outputHeight
                                                  standardRate:(double)standardRate
                                                    interlaced:(BOOL)interlaced
                                                         audio:(DeckLinkAudioConfig *)audio {
    DeckLinkFillBlock block = [fill copy];
    FrameFillFn fn = [block](int64_t frameIndex, uint8_t *buffer, int32_t rowBytes, int32_t width, int32_t height,
                             DeckLinkOutputSignal *signal) -> bool {
        return block(frameIndex, buffer, rowBytes, width, height, signal) ? true : false;
    };
    // D4a: derive the DISPLAY MODE from the output raster + standard rate (SDI scaling: 720p and DCI too). The
    // private start path falls back to 2160p23.98 if this resolves unknown or the card doesn't support it.
    BMDDisplayMode displayMode = BMDModeForRasterRate((int32_t)outputWidth, (int32_t)outputHeight, standardRate, interlaced);
    return [self startScheduledPlaybackWithFillFn:fn
                                      deviceIndex:deviceIndex
                                    initialSignal:initialSignal
                                      displayMode:displayMode
                                      audioConfig:audio];
}

- (void)stopScheduledPlayback {
    [self stopScheduledPlaybackEndingOnBlack:NO];
}

- (void)stopScheduledPlaybackEndingOnBlack:(BOOL)endOnBlack {
    _activeFrameSeconds = 0;
    if (_player != NULL) {
        const bool hadAudio = _player->audioEnabled();
        _player->stop(endOnBlack);   // StopScheduledPlayback → unset both callbacks → Disable audio → [final black] → Disable video → free pool/output
        // Final run summary (post-stop, so counts are settled).
        fprintf(stdout, "DeckLink D3: stopped — scheduled=%lld completed=%llu late=%llu dropped=%llu flushed=%llu\n",
                (long long)_player->framesScheduled(),
                (unsigned long long)_player->completedCount(),
                (unsigned long long)_player->lateCount(),
                (unsigned long long)_player->droppedCount(),
                (unsigned long long)_player->flushedCount());
        if (hadAudio) {
            // `scheduled` COUNTS BOTH KINDS OF FRAME. Every schedule — real PCM and digital silence
            // alike — goes through the one scheduleFrames() call that advances the audio stream time,
            // so the total says only "the card was fed a continuous stream", never "the card was fed
            // AUDIO". Nor do the counters beside it disambiguate: underruns / shortReads / resyncs are
            // all incremented inside the real path, AFTER the transport gate has returned, so a run
            // that scheduled nothing but silence reports zeroes for all three. Hence the explicit
            // split — read `real=`, never `scheduled=`, when asking whether audio reached SDI.
            const unsigned long long pcm     = (unsigned long long)_player->audioPcmFramesScheduled();
            const unsigned long long silence = (unsigned long long)_player->audioSilenceFramesScheduled();
            fprintf(stdout, "DeckLinkAudio: stopped — scheduled=%lldf TOTAL = real=%lluf (PCM read from "
                            "the ring) + silence=%lluf (transport gate / destination / no anchor / underrun / tail pad) "
                            "· underruns=%llu underrunEvents=%llu shortReads=%llu shortSchedules=%llu resyncs=%llu\n",
                    (long long)_player->audioFramesScheduled(), pcm, silence,
                    (unsigned long long)_player->audioUnderrunCount(),
                    (unsigned long long)_player->audioUnderrunEventCount(),
                    (unsigned long long)_player->audioShortReadCount(),
                    (unsigned long long)_player->audioShortScheduleCount(),
                    (unsigned long long)_player->audioResyncCount());
            _player->logRunsSummary();
            if (pcm == 0 && silence > 0) {
                fprintf(stdout, "DeckLinkAudio: stopped — real=0f: NO audio reached SDI this run. The "
                                "stream was continuous silence; the zero underruns/shortReads/resyncs "
                                "above are NOT evidence of healthy audio, they are what the silent "
                                "branch looks like (it returns before the ring is ever read).\n");
            }
        }
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
