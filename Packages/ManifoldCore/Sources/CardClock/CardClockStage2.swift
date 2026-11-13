//
//  CardClockStage2.swift
//  CardClock
//
//  Stage 2 (docs/CARD_CLOCK_FINDINGS.md §10.27): output on, a file with sound playing, at either destination. The card is the master
//  clock and the Mac's sound is resampled to follow THE SDI PICTURE. Pure pieces only: the switch, the card's line (slot against host),
//  and the picture line the SDI bridge publishes. Nothing here holds a synchronizer or a stage.
//
//  ── THE PICTURE LINE, AND WHY IT IS NOT THE BRIDGE'S RUN ─────────────────────────────────────
//
//  §10.27 planned to read Φ from the bridge's run (`m_run`). A run latches only while the bridge's gate is open, and at destination
//  Computer the gate is shut for the whole session, so there would be no run to read. The bridge instead publishes, at both
//  destinations, the line its runs latch on: for every timed slot that moved, φ = pts − slot × card frame, the content time at card time
//  0. Card slot n is on the wire, against its completion stamp, at a constant (the card's), so the content on the wire at host h is
//
//      w(h) = φ + cardTime(h)          cardTime(h) = slot(h) × card frame, from the completion stamps
//
//  At a matched rate φ is the run's D / sample rate exactly. A rate mismatch (C6) has a staircase, not a line: it is published as such
//  and Stage 2 holds there (not covered yet).
//

import Foundation

public enum CardClockStage2 {
    /// Stage 2 acts only with Stage 1b's gate on (`CardClockAudio.stage1b`). `MANIFOLD_CARDLOCK_STAGE2=0` turns it off and leaves 1c
    /// exactly as it was, for the baseline run (W1). Read once, at first use.
    public static let enabled = CardClockAudio.stage1b && ProcessInfo.processInfo.environment["MANIFOLD_CARDLOCK_STAGE2"] != "0"

    /// Above this the Mac's sound is not steered to the SDI picture but put there by one position write (§10.27, item 4). The same
    /// 20 ms as 1b's bound: a tenth of the tap's look-ahead, not any device's rate.
    public static let coarseBound = 0.020
    /// A NEW picture line while steering is a step of the SDI picture on the wire (a slip: the card repeated or skipped a frame, so φ
    /// moved by a whole frame; §10.29). The SDI sound steps with its picture there, so the Mac's sound does too: one position write, if
    /// the error is over this. Far above the read noise (≈ 0.2 ms p1–p99), below half a frame at any rate. Without it a 59.94 slip
    /// (16.7 ms, under `coarseBound`) was slewed for 2 min at up to 1,657 ppm, overshooting by 4 ms (W7, §10.29).
    public static let slipBound = 0.001
    /// How often the engine reads the pair and steps the controller. The controller's time constant is 10 s (kp 0.1).
    public static let tickHz = 10.0
    /// No picture line for a Play within this long: the sound starts with the picture clock instead, and says so.
    public static let startTimeout = 1.0
}

/// The card's slot against the host, fitted from its completion stamps: least squares over the newest `window` seconds.
public struct CardClockLine: Sendable, Equatable {
    public let frameSeconds: Double
    /// A point on the line: slot `slot0` completed at host `host0`.
    public let slot0: Int64
    public let host0: Double
    /// Card seconds per host second.
    public let rate: Double
    /// The newest sample's slot.
    public let newestSlot: Int64

    /// Card time (slot × frame) at host `h`.
    public func cardTime(atHost h: Double) -> Double { Double(slot0) * frameSeconds + (h - host0) * rate }
    /// Host time at which card time `c` passes.
    public func host(atCardTime c: Double) -> Double { host0 + (c - Double(slot0) * frameSeconds) / rate }

    /// Nil with fewer than 3 samples (it fits back only to a position step in the window). Under 0.5 s of samples, the slope says
    /// little, so the rate is held at 1 and only the offset is fitted: the card is within ±100 ppm of the host, under 50 µs over that
    /// half second, which the steering takes out. Without it an output start made while playing waited 0.5 s for its line and the
    /// sound started ~460 ms into the SDI picture's run (W6b, §10.29).
    public static func fit(_ samples: [CardClockSample], frameSeconds: Double, window: Double = 2.0) -> CardClockLine? {
        guard let newest = samples.last else { return nil }
        var fit: [CardClockSample] = []
        for s in samples.reversed() {
            if s.host < newest.host - window { break }
            if let later = fit.last, abs((later.host - s.host) - Double(later.slot - s.slot) * frameSeconds) > frameSeconds / 2 { break }
            fit.append(s)
        }
        guard fit.count >= 3, let origin = fit.last else { return nil }
        let n = Double(fit.count)
        var sx = 0.0, sy = 0.0
        for s in fit { sx += s.host - origin.host; sy += Double(s.slot - origin.slot) * frameSeconds }
        let mx = sx / n, my = sy / n
        if newest.host - origin.host < 0.5 {
            return CardClockLine(frameSeconds: frameSeconds, slot0: origin.slot, host0: origin.host + mx - my, rate: 1, newestSlot: newest.slot)
        }
        var sxy = 0.0, sxx = 0.0
        for s in fit {
            let x = s.host - origin.host - mx, y = Double(s.slot - origin.slot) * frameSeconds - my
            sxy += x * y; sxx += x * x
        }
        guard sxx > 0 else { return nil }
        let rate = sxy / sxx
        guard abs(rate - 1) < 0.01 else { return nil }
        // The line through the means: slot0 = origin, host0 where the fit puts it.
        let host0 = origin.host + mx - my / rate
        return CardClockLine(frameSeconds: frameSeconds, slot0: origin.slot, host0: host0, rate: rate, newestSlot: newest.slot)
    }
}

/// The SDI picture's line as the bridge last published it.
public struct CardPictureLine: Sendable, Equatable {
    /// Bumped each time φ changes (a Play, a seek, a loop's wrap, a hold).
    public var serial: UInt64
    /// Content seconds at card time 0.
    public var phi: Double
    /// The slot that started this line, and the newest slot seen on it.
    public var firstSlot: Int64
    public var lastSlot: Int64
    /// False: a rate mismatch (C6), a staircase with no line. Stage 2 holds.
    public var matched: Bool
    public init(serial: UInt64, phi: Double, firstSlot: Int64, lastSlot: Int64, matched: Bool) {
        self.serial = serial; self.phi = phi; self.firstSlot = firstSlot; self.lastSlot = lastSlot; self.matched = matched
    }
}

public final class CardPictureLineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var line: CardPictureLine?
    public init() {}
    /// Returns true when the serial is new.
    public func store(_ l: CardPictureLine) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let fresh = line?.serial != l.serial
        line = l
        return fresh
    }
    public func read() -> CardPictureLine? { lock.lock(); defer { lock.unlock() }; return line }
    public func reset() { lock.lock(); line = nil; lock.unlock() }
}
