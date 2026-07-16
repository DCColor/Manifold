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
    NSString *_activeModeName;
}
- (instancetype)initWithSuccess:(BOOL)success log:(NSArray<NSString *> *)log {
    return [self initWithSuccess:success log:log activeModeName:nil];
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
@end

#pragma mark - Audio config (D4b-2)

@implementation DeckLinkAudioConfig {
    double _sampleRate;
    NSInteger _sourceChannelCount;
    NSInteger _deckLinkChannelCount;
    double _trimSeconds;
    DeckLinkAudioSourceTimeBlock _sourceTime;
    DeckLinkAudioSilentBlock _isSilent;
    DeckLinkAudioReadBlock _read;
}
- (instancetype)initWithSampleRate:(double)sampleRate
                sourceChannelCount:(NSInteger)sourceChannelCount
              deckLinkChannelCount:(NSInteger)deckLinkChannelCount
                       trimSeconds:(double)trimSeconds
                        sourceTime:(DeckLinkAudioSourceTimeBlock)sourceTime
                          isSilent:(DeckLinkAudioSilentBlock)isSilent
                              read:(DeckLinkAudioReadBlock)read {
    if ((self = [super init])) {
        _sampleRate = sampleRate;
        _sourceChannelCount = sourceChannelCount;
        _deckLinkChannelCount = deckLinkChannelCount;
        _trimSeconds = trimSeconds;
        _sourceTime = [sourceTime copy];
        _isSilent = [isSilent copy];
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
    std::function<bool(void)> isSilent;                                      // mute / pause / shuttle gate
    std::function<int32_t(double, int32_t, int32_t *)> read;                 // ring read (D4b-1)
};

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
                            FrameFillFn fill, int64_t colorspace)
        : m_refCount(1), m_output(output), m_displayMode(displayMode),
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
        HRESULT hr = m_output->DoesSupportVideoMode(bmdVideoConnectionUnspecified, m_displayMode,
                                                    bmdFormat10BitYUV, bmdNoVideoOutputConversion,
                                                    bmdSupportedVideoModeDefault, &actual, &supported);
        return (hr == S_OK && supported);
    }

    bool enableOutput() {
        return m_output->EnableVideoOutput(m_displayMode, bmdVideoOutputFlagDefault) == S_OK;
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

    // --- D4b-2 audio setup (ordering matters; see the start sequence in the bridge) ---

    // (a) EnableAudioOutput. 32-bit signed integer samples (what the D4b-1 ring already stores),
    // TIMESTAMPED stream type (we position samples explicitly on the playback timeline via streamTime,
    // rather than letting the card append them blind). Channel count is the SDK-legal PADDED count.
    // Preallocates the two scratch buffers so the callback never allocates.
    bool enableAudio(const AudioSource &src) {
        m_audio = src;
        if (m_output->EnableAudioOutput((BMDAudioSampleRate)m_audio.sampleRate,
                                        bmdAudioSampleType32bitInteger,
                                        m_audio.dlChannels,
                                        bmdAudioOutputStreamTimestamped) != S_OK)
            return false;
        const size_t maxFrames = (size_t)std::lround(m_audio.sampleRate * kAudioMaxCallbackSeconds);
        m_maxCallbackFrames = (int32_t)maxFrames;
        m_srcScratch.assign(maxFrames * m_audio.srcChannels, 0);   // ring layout (source channels)
        m_outScratch.assign(maxFrames * m_audio.dlChannels, 0);    // wire layout (padded channels)
        m_audioEnabled = true;
        return true;
    }

    // (b)+(c) Register the pull callback and open the preroll window. The card starts calling
    // RenderAudioSamples(preroll=true) immediately, so the audio buffer prefills WHILE the video
    // preroll frames are being scheduled. Must be called after enableAudio(), before preroll().
    void beginAudioPreroll() {
        if (!m_audioEnabled) return;
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
    void stop() {
        m_running = false;
        if (m_output) {
            BMDTimeValue actualStop = 0;
            m_output->StopScheduledPlayback(0, &actualStop, m_timeScale);
            m_output->SetScheduledFrameCompletionCallback(NULL);
            if (m_audioEnabled) {
                m_prerollingAudio = false;
                m_output->SetAudioCallback(NULL);
                m_output->FlushBufferedAudioSamples();   // drop anything still queued
                m_output->DisableAudioOutput();
                m_audioEnabled = false;
            }
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
    //                   ideal = stagedPts + (audioDepth − videoDepth) + trim
    //
    //                 stagedPts is the source PTS of the frame in the DeckLink staging buffer (the frame
    //                 the fill block hands the card). audioDepth/videoDepth are the two pipelines' queue
    //                 depths — measured, not assumed — so the delta compensates the pipeline skew every
    //                 callback. Steering is a ≤2-sample skip/repeat per callback (see the constants).
    HRESULT RenderAudioSamples(bool preroll) override {
        if (!m_running.load() || !m_audioEnabled) return S_OK;

        uint32_t buffered = 0;
        if (m_output->GetBufferedAudioSampleFrameCount(&buffered) != S_OK) return E_FAIL;

        const double rate = (double)m_audio.sampleRate;
        const int32_t targetFrames = (int32_t)std::lround(rate * kAudioTargetDepthSeconds);

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
            return scheduleSilence(want) ? S_OK : E_FAIL;
        }

        // The anchor: source PTS of the frame in the DeckLink staging buffer. NaN → no converted frame
        // yet (output just started / no file) → nothing to align to, so hold silence.
        const double stagedPts = m_audio.sourceTime ? m_audio.sourceTime() : NAN;
        if (!std::isfinite(stagedPts)) {
            m_cursorAnchored = false;
            return scheduleSilence(want) ? S_OK : E_FAIL;
        }

        // Pipeline-depth delta. audioDepth: these samples queue BEHIND `buffered`, so they reach the
        // wire that much later. videoDepth: the staged frame is picked up by the next frame-completion
        // callback and then sits behind the frames already queued — hence the +1. Both are measured
        // from the card each callback, so a changing queue depth self-compensates.
        uint32_t bufferedVideo = 0;
        m_output->GetBufferedVideoFrameCount(&bufferedVideo);
        const double audioDepth = (double)buffered / rate;
        const double videoDepth = (double)(bufferedVideo + 1) * (double)m_frameDuration / (double)m_timeScale;
        const double ideal = stagedPts + (audioDepth - videoDepth) + m_audio.trimSeconds;

        int32_t correction = 0;
        if (!m_cursorAnchored) {
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
            m_cursorAnchored = false;
            m_errEma = 0.0;
            logUnderrunThrottled(m_cursorSeconds, want);
            return scheduleSilence(want) ? S_OK : E_FAIL;
        }
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

        const uint32_t written = scheduleFrames(dst, toSchedule);
        // Sample-continuous: the cursor advances ONLY over REAL frames that the card actually accepted.
        // Silence padding is deliberately NOT counted as source time consumed — the source audio it stood
        // in for is not skipped, it is simply late, and the anchor loop (or a resync) reconciles that.
        m_cursorSeconds += (double)std::min((int32_t)written, got) / rate;
        logPeriodic(buffered, bufferedVideo, written, got, want, correction, silencePad);
        return S_OK;
    }

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
        scheduleFrames(m_outScratch.data(), frames);
        return true;
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
                "%s) · vq=%uf · drift=%+.2fms · corr=%+df · underruns=%llu short=%llu resyncs=%llu\n",
                bufferedAudio, (double)bufferedAudio / rate * 1000.0, m_cursorSeconds,
                written, want, got, silencePad > 0 ? " +PAD" : "", bufferedVideo,
                m_errEma * 1000.0, correction,
                (unsigned long long)m_underruns, (unsigned long long)m_shortReads,
                (unsigned long long)m_resyncs);
        fflush(stdout);
    }

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
    BMDDisplayMode m_displayMode;   // the display mode this player enables/schedules (D4a: from the file)
    int32_t m_width, m_height, m_rowBytes;
    BMDTimeValue m_frameDuration;
    BMDTimeScale m_timeScale;
    FrameFillFn m_fill;
    std::vector<IDeckLinkMutableVideoFrame *> m_pool;
    std::atomic<bool> m_running;
    std::atomic<int64_t> m_nextIndex;
    std::atomic<uint64_t> m_completed, m_late, m_dropped, m_flushed;
    std::atomic<int64_t> m_colorspace;   // BMDColorspace tag (from source primaries), live-updatable

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
    double m_cursorSeconds = 0.0;           // SOURCE time of the next sample frame to schedule
    bool m_cursorAnchored = false;          // false → snap to the video's source time next callback
    double m_errEma = 0.0;                  // smoothed (ideal − cursor), seconds
    uint64_t m_underruns = 0;               // ring had NOTHING at the cursor → silence + re-anchor
    uint64_t m_shortReads = 0;              // ring had SOME but not all → short schedule (no hole)
    uint64_t m_shortSchedules = 0;          // card accepted fewer frames than offered
    uint64_t m_resyncs = 0;                 // smoothed drift exceeded the band → cursor snapped
    BMDTimeValue m_lastAudioLogFrames = 0;
    BMDTimeValue m_lastUnderrunLogFrames = 0;

public:
    uint64_t audioUnderrunCount() const { return m_underruns; }
    uint64_t audioShortReadCount() const { return m_shortReads; }
    uint64_t audioResyncCount()   const { return m_resyncs; }
    uint64_t audioShortScheduleCount() const { return m_shortSchedules; }
    BMDTimeValue audioFramesScheduled() const { return m_audioStreamFrames; }
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

#pragma mark - D4a: display-mode selection (video cadence from the file's resolution + rate)

// Map a resolution family (2160p vs 1080p) + a broadcast rate to the matching PROGRESSIVE BMDDisplayMode.
// `is2160` picks the family (true → 3840×2160, false → 1920×1080). The rate is matched by pure
// NEAREST-MATCH (minimum |Δfps|) against the 8 standard rates — NO ranges, NO boundaries, NO seams, so
// no input can be trapped on a bucket edge. The fractional NTSC rates use their EXACT n/1001 value
// (24000/1001 = 23.976…, 30000/1001 = 29.970…, 60000/1001 = 59.940…), so a 29.970 source lands ~0 from
// the 29.97 row and ~0.03 from the 30 row → p2997, never p30 and never a fallback. Every rate resolves
// to a real, card-supported progressive mode (all 8 are supported on device 0); interlaced is never
// selected (the decode path is progressive). Actual timing is read back off the resolved mode.
static BMDDisplayMode BMDModeForFamilyRate(bool is2160, double rate) {
    struct Row { double rate; BMDDisplayMode hd; BMDDisplayMode uhd; };
    static const Row rows[] = {
        {24000.0 / 1001.0, bmdModeHD1080p2398, bmdMode4K2160p2398},   // 23.976…
        {24.0,             bmdModeHD1080p24,   bmdMode4K2160p24},
        {25.0,             bmdModeHD1080p25,   bmdMode4K2160p25},
        {30000.0 / 1001.0, bmdModeHD1080p2997, bmdMode4K2160p2997},   // 29.970…
        {30.0,             bmdModeHD1080p30,   bmdMode4K2160p30},
        {50.0,             bmdModeHD1080p50,   bmdMode4K2160p50},
        {60000.0 / 1001.0, bmdModeHD1080p5994, bmdMode4K2160p5994},   // 59.940…
        {60.0,             bmdModeHD1080p6000, bmdMode4K2160p60},      // N.B. 1080p60 is bmdModeHD1080p6000
    };
    double best = 1e9; BMDDisplayMode bestMode = bmdModeUnknown;
    for (const Row &r : rows) {
        const double d = fabs(rate - r.rate);
        if (d < best) { best = d; bestMode = is2160 ? r.uhd : r.hd; }
    }
    return bestMode;   // pure nearest-match — always a real mode, never falls through on a seam
}

// Short human label for a resolved mode, e.g. "2160p23.98" / "1080p25" / "2160p59.94". The family
// comes from the height; the rate token is snapped to the standard broadcast strings so 24000/1001
// reads "23.98" (not "23.976") and 30000/1001 reads "29.97".
static NSString *ModeNameForResolved(int32_t width, int32_t height, BMDTimeValue frameDuration, BMDTimeScale timeScale) {
    const char *fam = (height >= 1620) ? "2160p" : "1080p";
    const double r = (frameDuration > 0) ? (double)timeScale / (double)frameDuration : 0.0;
    struct { double rate; const char *tok; } toks[] = {
        {24000.0 / 1001.0,"23.98"}, {24,"24"}, {25,"25"}, {30000.0 / 1001.0,"29.97"},
        {30,"30"}, {50,"50"}, {60000.0 / 1001.0,"59.94"}, {60,"60"}
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

// Private: the shared start sequence parameterized by a C++ FrameFillFn (C++ type in the selector,
// so it can only live in the .mm). Public entry points wrap their fill and forward here.
@interface DeckLinkBridge ()
- (DeckLinkOutputResult *)startScheduledPlaybackWithFillFn:(FrameFillFn)fill
                                               deviceIndex:(NSInteger)deviceIndex
                                                colorspace:(int64_t)colorspace
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
                                                colorspace:(int64_t)colorspace
                                               displayMode:(BMDDisplayMode)displayMode
                                               audioConfig:(DeckLinkAudioConfig *)audioConfig {
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
        if (output->GetDisplayMode(wantMode, &mode) != S_OK || mode == NULL) {
            [log addObject:@"mode: could not resolve fallback 2160p23.98 display mode — aborting"];
            output->Release();
            return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
        }
    }
    const int32_t width  = (int32_t)mode->GetWidth();
    const int32_t height = (int32_t)mode->GetHeight();
    BMDTimeValue frameDuration = 0; BMDTimeScale timeScale = 0;
    mode->GetFrameRate(&frameDuration, &timeScale);
    mode->Release();
    NSString *modeName = ModeNameForResolved(width, height, frameDuration, timeScale);
    int32_t rowBytes = 0;
    output->RowBytesForPixelFormat(bmdFormat10BitYUV, width, &rowBytes);   // authoritative v210 stride (128-aligned)
    [log addObject:[NSString stringWithFormat:@"mode: %@ (%dx%d @ %lld/%lld duration/timescale), v210 rowBytes=%d",
                    modeName, width, height, (long long)timeScale, (long long)frameDuration, rowBytes]];

    // Build the player (SEAM: fill source is pluggable — synthetic hue-walk for D3). The player
    // AddRefs the output; drop our local ref. `colorspace` is the output signal tag (from source
    // primaries) applied to each scheduled frame's metadata. The resolved `wantMode` drives
    // EnableVideoOutput + DoesSupportVideoMode.
    DeckLinkScheduledPlayer *player =
        new DeckLinkScheduledPlayer(output, wantMode, width, height, rowBytes, frameDuration, timeScale, fill, colorspace);
    output->Release();
    [log addObject:[NSString stringWithFormat:@"tag: output colorspace = %@",
                    (colorspace == bmdColorspaceRec2020 ? @"Rec. 2020" : @"Rec. 709")]];

    if (!player->doesSupportMode()) {
        [log addObject:[NSString stringWithFormat:@"mode: %@ / v210 10-bit YUV NOT supported — aborting", modeName]];
        player->stop(); player->Release();
        return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
    }
    [log addObject:[NSString stringWithFormat:@"mode: %@ / v210 10-bit YUV supported", modeName]];

    if (!player->enableOutput()) {
        [log addObject:@"enable: EnableVideoOutput failed — aborting"];
        player->stop(); player->Release();
        return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
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
        DeckLinkAudioReadBlock readBlock = [audioConfig.read copy];
        src.sourceTime = [timeBlock]() -> double { return timeBlock(); };
        src.isSilent   = [silentBlock]() -> bool { return silentBlock() ? true : false; };
        src.read       = [readBlock](double t, int32_t n, int32_t *dst) -> int32_t { return readBlock(t, n, dst); };
        if (!player->enableAudio(src)) {
            [log addObject:[NSString stringWithFormat:
                @"audio: EnableAudioOutput(%u Hz, 32-bit int, %u ch, timestamped) failed — aborting",
                src.sampleRate, src.dlChannels]];
            player->stop(); player->Release();
            return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
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
    if (!player->createPool(poolSize)) {
        [log addObject:@"pool: CreateVideoFrame failed — aborting"];
        player->stop(); player->Release();
        return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
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

    if (!player->preroll()) {
        [log addObject:@"preroll: ScheduleVideoFrame failed — aborting"];
        player->stop(); player->Release();
        return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
    }
    [log addObject:[NSString stringWithFormat:@"preroll: %d frames scheduled (indices 0..%d)", poolSize, poolSize - 1]];

    // Close the audio preroll window if the callback hasn't already (it ends it itself the moment the
    // buffer hits the target depth). Exactly-once — the two threads race for it by design.
    if (player->audioEnabled()) {
        player->endAudioPrerollIfNeeded();
        [log addObject:@"audio: EndAudioPreroll — audio stream armed"];
    }

    if (!player->startPlayback()) {
        [log addObject:@"start: StartScheduledPlayback failed — aborting"];
        player->stop(); player->Release();
        return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
    }
    [log addObject:[NSString stringWithFormat:@"start: StartScheduledPlayback(0, %lld, 1.0) OK — free-running at %@%@",
                    (long long)timeScale, modeName, player->audioEnabled() ? @" (video + SDI audio)" : @" (video only)"]];

    _player = player;   // held; callback keeps the pipeline full until -stopScheduledPlayback
    return [[DeckLinkOutputResult alloc] initWithSuccess:YES log:log activeModeName:modeName];
}

// Public: synthetic hue-walk on device 0 (D3 — debug/fallback). No source → tag Rec.709, 2160p23.98,
// and no audio (there is no source to serve).
- (DeckLinkOutputResult *)startScheduledPlaybackOnDevice0 {
    return [self startScheduledPlaybackWithFillFn:FrameFillFn(&SyntheticHueWalkFill)
                                      deviceIndex:0
                                       colorspace:bmdColorspaceRec709
                                      displayMode:bmdMode4K2160p2398
                                      audioConfig:nil];
}

// Public: REAL video (D-real) on a chosen device. Wrap the Obj-C fill block into the C++ FrameFillFn
// the scheduler expects; the std::function retains the (heap-copied) block for the player's lifetime.
// The block itself sources pixels (renderer.copyLatest…) and handles the neutral fallback — the
// scheduler stays source-agnostic. `primariesCode` → the output colorspace TAG (SEPARATE from the
// kernel's encoding matrix, which the renderer selects from the matrix code).
- (DeckLinkOutputResult *)startScheduledPlaybackWithDeviceIndex:(NSInteger)deviceIndex
                                                          fill:(DeckLinkFillBlock)fill
                                                 primariesCode:(NSInteger)primariesCode
                                                   outputWidth:(NSInteger)outputWidth
                                                  outputHeight:(NSInteger)outputHeight
                                                  standardRate:(double)standardRate
                                                         audio:(DeckLinkAudioConfig *)audio {
    DeckLinkFillBlock block = [fill copy];
    FrameFillFn fn = [block](int64_t frameIndex, uint8_t *buffer, int32_t rowBytes, int32_t width, int32_t height) {
        (void)block(frameIndex, buffer, rowBytes, width, height);
    };
    // D4a: derive the DISPLAY MODE from the output-family resolution + standard rate. The private
    // start path falls back to 2160p23.98 if this resolves unknown or the card doesn't support it.
    const bool is2160 = (outputHeight >= 1620);
    BMDDisplayMode displayMode = BMDModeForFamilyRate(is2160, standardRate);
    return [self startScheduledPlaybackWithFillFn:fn
                                      deviceIndex:deviceIndex
                                       colorspace:BMDColorspaceForPrimaries(primariesCode)
                                      displayMode:displayMode
                                      audioConfig:audio];
}

// Update the output colorspace tag mid-session (source colorspace changed while output is running).
// Per-schedule tagging means the next scheduled frame picks this up — no in-flight re-tag race.
- (void)setOutputColorspaceForPrimaries:(NSInteger)primariesCode {
    if (_player != NULL) { _player->setColorspace(BMDColorspaceForPrimaries(primariesCode)); }
}

- (void)stopScheduledPlayback {
    if (_player != NULL) {
        const bool hadAudio = _player->audioEnabled();
        _player->stop();      // StopScheduledPlayback → unset both callbacks → Disable audio + video → free pool/output
        // Final run summary (post-stop, so counts are settled).
        fprintf(stdout, "DeckLink D3: stopped — scheduled=%lld completed=%llu late=%llu dropped=%llu flushed=%llu\n",
                (long long)_player->framesScheduled(),
                (unsigned long long)_player->completedCount(),
                (unsigned long long)_player->lateCount(),
                (unsigned long long)_player->droppedCount(),
                (unsigned long long)_player->flushedCount());
        if (hadAudio) {
            fprintf(stdout, "DeckLinkAudio: stopped — scheduled=%lldf underruns=%llu shortReads=%llu "
                            "shortSchedules=%llu resyncs=%llu\n",
                    (long long)_player->audioFramesScheduled(),
                    (unsigned long long)_player->audioUnderrunCount(),
                    (unsigned long long)_player->audioShortReadCount(),
                    (unsigned long long)_player->audioShortScheduleCount(),
                    (unsigned long long)_player->audioResyncCount());
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
