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
@end

NS_ASSUME_NONNULL_END
