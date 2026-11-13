//
//  CardAudioResample.swift
//  LiveAudioResample
//
//  Stage 2 (docs/CARD_CLOCK_FINDINGS.md §10.27): a FILE's sound on the Mac resampled to follow the card. One per audio arm, in the pump's
//  enqueue closure AFTER the tap, so the tap and SDI keep the original samples. The live sources' stage (`LiveAudioResampleStage`) does
//  the work; this wraps it with what a file needs and a live source does not:
//
//    * ACTIVE OR NOT. The arm is built before anyone knows whether output will start, and the renderer moves to its own clock only when it
//      does. Inactive, buffers pass through untouched, exactly as before Stage 2. `activate` and `deactivate` are called at the START of
//      a renderer move: the move flushes the renderer, so nothing from one side of the switch is heard beside the other.
//    * AN AXIS OFFSET. The renderer's timeline is the stage's output axis, which drifts from content time by Σ(ρ − 1)·dt. A seek writes
//      both clocks to content time and a new arm starts at offset 0. A re-read that keeps the clock (an automatic flush after a device
//      change, a track switch) must land its first sample where the old arm's output axis had it, so it is built with
//      `axisOffset` = (old output time of the content) − content, added to every input pts.
//
//  Nothing here touches a synchronizer. ρ is written only by `CardAudioSteering`, through `apply`.
//

import CoreMedia
import Foundation

public final class CardAudioResample: @unchecked Sendable {
    private let lock = NSLock()
    private var stage: LiveAudioResampleStage?
    private let tag: String
    private let reportsWindows: Bool
    private let log: (@Sendable (String) -> Void)?
    /// Seconds added to every input pts while active.
    public let axisOffset: Double

    public init(axisOffset: Double, tag: String = "[CARDLOCK-RESAMPLE]", reportsWindows: Bool, log: (@Sendable (String) -> Void)?) {
        self.axisOffset = axisOffset; self.tag = tag; self.reportsWindows = reportsWindows; self.log = log
    }

    public var isActive: Bool { lock.lock(); defer { lock.unlock() }; return stage != nil }

    /// From the next buffer on, resampled. A no-op if already active.
    public func activate() {
        lock.lock(); defer { lock.unlock() }
        guard stage == nil else { return }
        stage = LiveAudioResampleStage(tag: tag, reportsWindows: reportsWindows, log: log)
    }

    /// From the next buffer on, passed through. The stage is retired (it never emits again).
    public func deactivate() {
        lock.lock(); let s = stage; stage = nil; lock.unlock()
        s?.retire()
    }

    /// The pump's enqueue: what to hand the renderer for `sb`.
    public func process(_ sb: CMSampleBuffer) -> [CMSampleBuffer] {
        lock.lock(); let s = stage; lock.unlock()
        guard let s else { return [sb] }
        guard axisOffset != 0 else { return s.process(sb) }
        return s.process(Self.shifted(sb, by: axisOffset) ?? sb)
    }

    /// Content seconds heard at renderer time `outputSeconds`. Identity, less the offset, before the first block or while inactive.
    public func contentTime(atOutputTime outputSeconds: Double) -> Double {
        lock.lock(); let s = stage; lock.unlock()
        return (s?.inputTime(atOutputTime: outputSeconds) ?? outputSeconds) - axisOffset
    }

    /// Renderer time at which content `contentSeconds` is heard.
    public func outputTime(atContentTime contentSeconds: Double) -> Double {
        lock.lock(); let s = stage; lock.unlock()
        let input = contentSeconds + axisOffset
        return s?.outputTime(atInputTime: input) ?? input
    }

    /// ρ now (1 while inactive).
    public var rho: Double { lock.lock(); let s = stage; lock.unlock(); return s?.rho ?? 1 }

    /// Cumulative counters of the current stage.
    public var totals: LiveAudioResampleStage.Stats? { lock.lock(); let s = stage; lock.unlock(); return s?.totals }

    /// The steering's ρ, onto the stage. Only `CardAudioSteering` calls this.
    fileprivate func apply(rho: Double) {
        lock.lock(); let s = stage; lock.unlock()
        s?.rho = rho
    }

    public func retire() { deactivate() }

    /// `sb` with every pts moved by `seconds`, rounded to whole samples at its own rate.
    private static func shifted(_ sb: CMSampleBuffer, by seconds: Double) -> CMSampleBuffer? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee, asbd.mSampleRate > 0 else { return nil }
        let scale = CMTimeScale(asbd.mSampleRate)
        let pts = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sb), timescale: scale, method: .roundHalfAwayFromZero)
        guard pts.isNumeric else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: scale),
                                        presentationTimeStamp: CMTime(value: pts.value + Int64((seconds * asbd.mSampleRate).rounded()), timescale: scale),
                                        decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: 1,
                                                    sampleTimingArray: &timing, sampleBufferOut: &out) == noErr else { return nil }
        return out
    }
}

/// The control law (§2.2's adopted gains, `LiveAudioResampleController`) for a file against the SDI picture. Main actor in use; a value
/// type, so it holds no lock. `e = m − (w + K)`: + means the Mac's sound is ahead of the SDI picture.
public struct CardAudioSteering: Sendable {
    public private(set) var state = LiveAudioResampleController.State()
    public let gains: LiveAudioResampleController.Gains
    public init(gains: LiveAudioResampleController.Gains = .adopted) { self.gains = gains }

    /// One step: the error, the seconds since the last step. Writes ρ onto `resample`.
    public mutating func step(error: Double, dt: Double, resample: CardAudioResample) {
        state = LiveAudioResampleController.step(state, error: error, dt: dt, gains: gains)
        resample.apply(rho: state.rho)
    }

    /// ρ carried onto a new arm's stage (the integrator's learned rate is the clocks', not the arm's).
    public func carry(onto resample: CardAudioResample) { resample.apply(rho: state.rho) }

    /// A position step (a coarse write, a new run): the filter re-seeds, the integrator is held (§2.4).
    public mutating func coarseEvent() { state = LiveAudioResampleController.coarseEvent(state) }

    /// A different output device: it has its own rate against the card, so what the integrator learned no longer applies.
    public mutating func resetIntegrator(resample: CardAudioResample?) {
        state = LiveAudioResampleController.State()
        if let resample { resample.apply(rho: 1) }
    }
}
