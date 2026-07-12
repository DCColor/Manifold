#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A single output-capable DeckLink device (D1: enumerate only — no modes, no output yet).
/// Pure value object; no C++/COM types leak into Swift.
@interface DeckLinkDeviceInfo : NSObject
/// Position in the driver's device enumeration (0-based).
@property (nonatomic, readonly) NSInteger index;
/// Base model string as reported by the driver, e.g. "DeckLink 8K Pro".
@property (nonatomic, copy, readonly) NSString *modelName;
/// Human display name (may include the connection/topology), e.g. "DeckLink 8K Pro (1)".
@property (nonatomic, copy, readonly) NSString *displayName;
@end

/// Result of a D2 output attempt: overall success + a step-by-step log so a failure is
/// diagnosable at the exact step (version floor / mode support / enable / create / fill / display).
@interface DeckLinkOutputResult : NSObject
@property (nonatomic, readonly) BOOL success;
@property (nonatomic, copy, readonly) NSArray<NSString *> *log;
/// D4a: the display mode actually established (e.g. "2160p23.98", "1080p25"), reflecting any
/// support fallback. nil on failure / paths that don't resolve a mode. Lets the UI status line show
/// the REAL active mode instead of a hardcoded string.
@property (nonatomic, copy, readonly, nullable) NSString *activeModeName;
@end

/// Fill callback for D-real real-video output: fill the DeckLink v210 frame at `buffer` (row
/// stride `rowBytes`, `width`×`height`) for output frame index `frameIndex`. Returns YES if it
/// wrote real converted video, NO if it filled a neutral fallback (advisory). Runs on the SDK
/// callback thread — must be cheap (a memcpy), never blocking.
typedef BOOL (^DeckLinkFillBlock)(int64_t frameIndex, uint8_t *buffer, int32_t rowBytes, int32_t width, int32_t height);

#pragma mark - D4b-2: SDI audio output

/// The SOURCE TIME (seconds) of the video frame currently in the DeckLink staging buffer — i.e. the
/// frame the fill block is about to hand (or has just handed) to the card. NaN when no converted
/// frame is ready. This is the anchor the audio stream is keyed to: serving audio at the source time
/// the VIDEO carries makes A/V alignment structural rather than a wall-clock guess. Called on the SDK
/// audio-callback thread (~50 Hz) — must be a cheap lock-guarded read.
typedef double (^DeckLinkAudioSourceTimeBlock)(void);

/// YES → the SDI audio stream must carry SILENCE this callback (user mute, pause, or an off-speed
/// JKL shuttle). The card is still fed (zeros), never starved. Called on the SDK audio-callback thread.
typedef BOOL (^DeckLinkAudioSilentBlock)(void);

/// Copy up to `frameCount` interleaved int32 frames of SOURCE-channel PCM starting at source time
/// `startTime` (seconds) into `dst` (capacity `frameCount * sourceChannelCount` int32). Returns the
/// number of frames actually available and copied — 0 when `startTime` is outside the ring's retained
/// window (post-seek gap / decoder hasn't reached it). Never blocks beyond a lock; never returns stale
/// or repeated samples. This is AudioTapBuffer.read (D4b-1). Called on the SDK audio-callback thread.
typedef int32_t (^DeckLinkAudioReadBlock)(double startTime, int32_t frameCount, int32_t *dst);

/// Everything the bridge needs to run the SDI audio stream. Passed at start; nil → video-only output
/// (the D4b-1 arc's prior behavior, unchanged). All blocks run on the SDK audio-callback thread.
@interface DeckLinkAudioConfig : NSObject
/// Source sample rate (Hz). The SDK accepts 48000 and NOTHING else (BMDAudioSampleRate has exactly one
/// member) — the caller must refuse/report a non-48k source rather than mis-signal it.
@property (nonatomic, readonly) double sampleRate;
/// Interleaved channel count the ring actually stores (what `read` writes).
@property (nonatomic, readonly) NSInteger sourceChannelCount;
/// SDK-legal embedded-channel count (2/8/16/32/64) the card is enabled with. Source channels are
/// interleaved into this at SCHEDULE time; the extra channels carry silence.
@property (nonatomic, readonly) NSInteger deckLinkChannelCount;
/// Residual-latency trim (seconds) added to the target source time. The (audio-buffer − video-queue)
/// depth difference is measured and compensated each callback; this knob only mops up what those two
/// depths don't capture (the staging hop, the card's embedder/DAC latency). + → audio pulled EARLIER
/// in the source (audio arrives sooner on the wire). Default 0.
@property (nonatomic, readonly) double trimSeconds;
@property (nonatomic, copy, readonly) DeckLinkAudioSourceTimeBlock sourceTime;
@property (nonatomic, copy, readonly) DeckLinkAudioSilentBlock isSilent;
@property (nonatomic, copy, readonly) DeckLinkAudioReadBlock read;

- (instancetype)initWithSampleRate:(double)sampleRate
                sourceChannelCount:(NSInteger)sourceChannelCount
              deckLinkChannelCount:(NSInteger)deckLinkChannelCount
                      trimSeconds:(double)trimSeconds
                        sourceTime:(DeckLinkAudioSourceTimeBlock)sourceTime
                          isSilent:(DeckLinkAudioSilentBlock)isSilent
                              read:(DeckLinkAudioReadBlock)read;
@end

/// Objective-C++ bridge to the Blackmagic DeckLink SDK. The .mm side does all the C++/COM work
/// (reference-counted interfaces, Release() on each) and hands back plain Obj-C value objects so
/// Swift never sees a C++ type.
@interface DeckLinkBridge : NSObject
/// Enumerate connected DeckLink devices that support output (playback), i.e. those exposing
/// IDeckLinkOutput. Returns an empty array if the driver isn't reachable or no card is present.
+ (NSArray<DeckLinkDeviceInfo *> *)enumerateOutputDevices;

/// D2 "first light": push ONE synthetic solid-color frame out device index 0 at 2160p23.98 /
/// 8-bit YUV via DisplayVideoFrameSync, and HOLD it on the output (output stays enabled, frame
/// retained) so it stays on the monitor. Enforces the Desktop Video >= 14.3 floor first. Hardcoded
/// device 0 + mode + format for D2 (real device selection / profile-awareness is a later stage).
/// Safe to call repeatedly (re-fires cleanly). Returns a per-step log.
- (DeckLinkOutputResult *)startTestFrameOutputOnDevice0;

/// Disable the output opened by -startTestFrameOutputOnDevice0 and release its held frame + output.
- (void)stopTestOutput;

/// D3 "scheduled playback": start CONTINUOUS free-running output on device 0 at 2160p23.98 /
/// v210 10-bit YUV, driven by the frame-completion callback against the card's hardware clock. Frames
/// are SYNTHETIC (a per-frame hue walk) via a pluggable fill source; the scheduling loop is
/// source-agnostic. Enforces the Desktop Video >= 14.3 floor. Runs until -stopScheduledPlayback.
/// Safe to call repeatedly. Returns a step log. (Debug/fallback path — see the WithFill: variant.)
- (DeckLinkOutputResult *)startScheduledPlaybackOnDevice0;

/// D-real / D5: scheduled playback on the device at `deviceIndex`, each frame filled by `fill`. The
/// block receives the DeckLink v210 frame pointer (+ dims/rowBytes) and must fill it (returning YES
/// for real data, NO for the neutral fallback — advisory); it runs on the SDK callback thread so it
/// MUST be cheap (a memcpy). `primariesCode` sets the output colorspace TAG (Rec.709 / Rec.2020;
/// P3 → Rec.2020) — SEPARATE from the encoding matrix (the renderer picks that from the matrix code).
///
/// D4a: `outputWidth`/`outputHeight`/`standardRate` select the DISPLAY MODE (video cadence). Pass the
/// resolved output-family resolution (3840×2160 or 1920×1080) + a standard broadcast rate (23.976 /
/// 24 / 25 / 29.97 / 30 / 50 / 59.94 / 60); the bridge maps them to the matching BMDDisplayMode,
/// checks DoesSupportVideoMode(v210, output), and falls back to 2160p23.98 if unsupported. The
/// scheduling timing (frameDuration/timeScale) follows the resolved mode. Result.activeModeName
/// reports the mode actually established.
///
/// D4b-2: pass `audio` to embed SDI audio on the same output, clock-anchored to the video on the wire
/// (the stream is enabled/prerolled/started inside this one call, in the SDK's required order). Pass
/// nil for video-only.
- (DeckLinkOutputResult *)startScheduledPlaybackWithDeviceIndex:(NSInteger)deviceIndex
                                                          fill:(DeckLinkFillBlock)fill
                                                 primariesCode:(NSInteger)primariesCode
                                                   outputWidth:(NSInteger)outputWidth
                                                  outputHeight:(NSInteger)outputHeight
                                                  standardRate:(double)standardRate
                                                         audio:(nullable DeckLinkAudioConfig *)audio;

/// Re-tag the output colorspace mid-session (source primaries changed while output is running). The
/// next scheduled frame picks it up. No-op if not currently playing.
- (void)setOutputColorspaceForPrimaries:(NSInteger)primariesCode;

/// Stop scheduled playback cleanly (StopScheduledPlayback → unset callback → DisableVideoOutput →
/// release frame pool + callback). Safe to call when not playing; safe against an in-flight callback.
- (void)stopScheduledPlayback;
@end

NS_ASSUME_NONNULL_END
