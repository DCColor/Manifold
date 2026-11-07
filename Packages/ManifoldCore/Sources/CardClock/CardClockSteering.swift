//
//  CardClockSteering.swift
//  CardClock
//
//  The card as master clock during file playback (docs/CARD_CLOCK_FINDINGS.md §10.1): what to write to the file clock, as pure
//  logic. It holds no clock, no timer and no synchronizer, so every case is testable without a card.
//
//  The card gives one sample per completed frame: its slot count and a stamp on the host axis. Card time is slot × frame duration.
//  While the file clock runs at 1× the steering holds `clock − card time` constant:
//
//      φ      = clock − card time, latched when a run starts
//      rate   = least-squares slope of card time against host, over the last `fitWindow`
//      write  = setRate(rate, time: card time(n) + φ, atHostTime: stamp(n))
//
//  ⚠️ THE HOST TIME MUST BE IN THE PAST, WHICH IS WHY A STAMP IS USED AND WHY `writeAge` EXISTS. Measured (§10.1): a host time in the
//  future stops the running clock for that long on every write, and a bare `rate =` write loses 80–145 µs. A host time 5 ms or more
//  in the past lands on the line, to a median of 0.2 µs.
//
//  ⚠️ NOTHING HERE MAY ASSUME THE CARD FREE-RUNS. A genlocked card is the same code reporting a different line. No rate is stored
//  anywhere: −11.67 ppm is one card on one night. The settings below come from the requirement that the rate can step within about
//  2 s (`fitWindow`) or from what a frame is (half a frame), never from a measured rate.
//

public struct CardClockSample: Sendable, Equatable {
    public var slot: Int64
    /// When the frame completed, in host seconds.
    public var host: Double
    public init(slot: Int64, host: Double) { self.slot = slot; self.host = host }
}

public struct CardClockSteering: Sendable {

    public struct Settings: Sendable, Equatable {
        /// The rate is fitted over this much of the newest samples. Short enough to follow a step that takes about 2 s.
        public var fitWindow = 2.0
        /// No fit over less than this: too short a span reads callback-free noise as rate.
        public var minimumFitSpan = 0.5
        /// A write uses the newest sample at least this old, so its host time is safely past (see the note above).
        public var writeAge = 0.005
        /// No sample for this long: the card has stalled. Hold the last rate and write nothing.
        public var staleAfter = 0.5
        /// Further than this from 1.0 is not a clock, it is a bad reading. 1 %, some 100× any oscillator.
        public var credibleRate = 0.01
        public init() {}
    }

    public enum Latch: String, Sendable { case run, transport, cardStep }
    public enum Wait: String, Sendable { case noSamples, stale, noFit, badRate, settling }

    public struct Write: Sendable, Equatable {
        public var rate: Double
        public var time: Double
        public var host: Double
        /// Where the clock was against the line at this write, seconds, + = clock ahead. Zero on a latch, which defines the line.
        public var error: Double
        /// Set when this write began a new line.
        public var latched: Latch?
    }

    public enum Decision: Sendable, Equatable {
        /// The clock is not running at 1×: nothing to do, and the next run latches afresh.
        case idle
        /// Running, but no write this tick.
        case wait(Wait)
        case write(Write)
    }

    public let frameSeconds: Double
    public let settings: Settings
    private var phi: Double?
    private var pendingLatch = Latch.run
    private var lastRead: (clock: Double, host: Double)?
    private var lastRate = 1.0
    private var handledStepHost = -Double.infinity

    public init(frameSeconds: Double, settings: Settings = Settings()) {
        self.frameSeconds = frameSeconds
        self.settings = settings
    }

    public var isLatched: Bool { phi != nil }

    /// One tick. `samples` are oldest first; `clock` was read at host time `clockHost`; `running` is the transport's word that the clock
    /// is at 1×. A transport move while running (a seek, a loop wrap) needs no call: the clock leaves the line by more than half a
    /// frame, and that is what is seen.
    public mutating func tick(samples: [CardClockSample], clock: Double, clockHost: Double, running: Bool) -> Decision {
        guard running else {
            phi = nil; lastRead = nil; pendingLatch = .run
            return .idle
        }
        let halfFrame = frameSeconds / 2
        guard let newest = samples.last else { return .wait(.noSamples) }
        guard clockHost - newest.host <= settings.staleAfter else { return .wait(.stale) }
        guard let at = samples.last(where: { $0.host <= clockHost - settings.writeAge }) else { return .wait(.noSamples) }

        // The fit's samples: back from `at`, within the window, and stopping at a position step in the card's own line.
        var fit: [CardClockSample] = []
        var stepHost: Double?
        for s in samples.reversed() where s.host <= at.host {
            if s.host < at.host - settings.fitWindow { break }
            if let later = fit.last {
                let expected = Double(later.slot - s.slot) * frameSeconds
                if abs((later.host - s.host) - expected) > halfFrame { stepHost = later.host; break }
            }
            fit.append(s)
        }
        if let stepHost, stepHost > handledStepHost {
            handledStepHost = stepHost
            phi = nil; lastRead = nil; pendingLatch = .cardStep
        }
        guard let first = fit.last, at.host - first.host >= settings.minimumFitSpan,
              let rate = Self.slope(fit, frameSeconds: frameSeconds) else { return .wait(.noFit) }
        guard abs(rate - 1) <= settings.credibleRate else { return .wait(.badRate) }

        let card = Double(at.slot) * frameSeconds
        let clockAtSample = clock - (clockHost - at.host) * lastRate

        if let phi {
            let line = card + phi
            let error = clockAtSample - line
            if abs(error) <= halfFrame {
                lastRate = rate
                return .write(Write(rate: rate, time: line, host: at.host, error: error, latched: nil))
            }
            // Off the line by more than a card could put it: the transport moved the clock.
            self.phi = nil; lastRead = nil; pendingLatch = .transport
        }
        // A new line, once the clock is seen to run: "rate 1" can be set while the synchronizer still waits for media.
        defer { lastRead = (clock, clockHost) }
        guard let last = lastRead, clockHost > last.host,
              abs((clock - last.clock) / (clockHost - last.host) - 1) <= settings.credibleRate else {
            return .wait(.settling)
        }
        phi = clockAtSample - card
        lastRate = rate
        return .write(Write(rate: rate, time: clockAtSample, host: at.host, error: 0, latched: pendingLatch))
    }

    /// Slope of card time against host, relative to the first sample so nothing large is squared.
    private static func slope(_ samples: [CardClockSample], frameSeconds: Double) -> Double? {
        guard samples.count >= 3, let origin = samples.last else { return nil }
        let n = Double(samples.count)
        var sx = 0.0, sy = 0.0
        for s in samples { sx += s.host - origin.host; sy += Double(s.slot - origin.slot) * frameSeconds }
        let mx = sx / n, my = sy / n
        var sxy = 0.0, sxx = 0.0
        for s in samples {
            let x = s.host - origin.host - mx, y = Double(s.slot - origin.slot) * frameSeconds - my
            sxy += x * y; sxx += x * x
        }
        return sxx > 0 ? sxy / sxx : nil
    }
}
