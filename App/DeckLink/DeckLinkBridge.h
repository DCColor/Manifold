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
@end

/// Fill callback for D-real real-video output: fill the DeckLink v210 frame at `buffer` (row
/// stride `rowBytes`, `width`×`height`) for output frame index `frameIndex`. Returns YES if it
/// wrote real converted video, NO if it filled a neutral fallback (advisory). Runs on the SDK
/// callback thread — must be cheap (a memcpy), never blocking.
typedef BOOL (^DeckLinkFillBlock)(int64_t frameIndex, uint8_t *buffer, int32_t rowBytes, int32_t width, int32_t height);

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

/// D-real: same scheduled playback on the device at `deviceIndex`, but each frame is filled by the
/// supplied block instead of the synthetic hue walk. The block receives the DeckLink v210 frame
/// pointer (+ dims/rowBytes) and must fill it (returning YES if it wrote real data, NO if it fell
/// back to neutral — advisory). Called on the SDK's callback thread, so the block MUST be cheap (a
/// memcpy) — no blocking work.
- (DeckLinkOutputResult *)startScheduledPlaybackWithDeviceIndex:(NSInteger)deviceIndex fill:(DeckLinkFillBlock)fill;

/// Stop scheduled playback cleanly (StopScheduledPlayback → unset callback → DisableVideoOutput →
/// release frame pool + callback). Safe to call when not playing; safe against an in-flight callback.
- (void)stopScheduledPlayback;
@end

NS_ASSUME_NONNULL_END
