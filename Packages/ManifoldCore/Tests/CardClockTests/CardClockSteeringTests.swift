import XCTest
@testable import CardClock

/// A simulated card and file clock: the clock follows the last write exactly, as measured for a past-host write (§10.1).
private struct Sim {
    let frame: Double
    var cardRate: Double                 // card seconds per host second
    var slot: Int64 = 0
    var nextHost = 0.0
    var samples: [CardClockSample] = []
    var line: (time: Double, host: Double, rate: Double) = (0, 0, 1)
    var steering: CardClockSteering
    var jitter: () -> Double = { 0 }

    init(frame: Double = 1001.0 / 60000, cardRate: Double) {
        self.frame = frame; self.cardRate = cardRate; steering = CardClockSteering(frameSeconds: frame)
    }
    func clock(at host: Double) -> Double { line.time + (host - line.host) * line.rate }

    /// Run to `host`, generating card frames, then tick once.
    mutating func tick(at host: Double, running: Bool = true) -> CardClockSteering.Decision {
        while nextHost <= host {
            samples.append(CardClockSample(slot: slot, host: nextHost + jitter()))
            slot += 1; nextHost += frame / cardRate
        }
        if samples.count > 1024 { samples.removeFirst(samples.count - 1024) }
        let d = steering.tick(samples: samples, clock: clock(at: host), clockHost: host, running: running)
        if case .write(let w) = d { line = (w.time, w.host, w.rate) }
        return d
    }
    /// The file clock against card time, seconds.
    func offset(at host: Double) -> Double { clock(at: host) - (Double(slot - 1) * frame + (host - (nextHost - frame / cardRate)) * cardRate) }
}

final class CardClockSteeringTests: XCTestCase {

    func testNoFixedRate() {
        for ppm in [-125.0, -11.67, 0, 40, 95] {
            var s = Sim(cardRate: 1 + ppm * 1e-6)
            var t = 3.0
            _ = s.tick(at: t); t += 1; _ = s.tick(at: t); t += 1
            let start = s.offset(at: t)
            var last: Double = .nan
            for _ in 0..<3600 {
                guard case .write(let w) = s.tick(at: t) else { return XCTFail("no write at \(ppm)") }
                last = w.rate; t += 1
            }
            XCTAssertEqual(last, 1 + ppm * 1e-6, accuracy: 1e-8)
            XCTAssertEqual(s.offset(at: t), start, accuracy: 5e-6, "the clock left the card at \(ppm) ppm")
        }
    }

    func testRateStepStaysInsideHysteresis() {
        var s = Sim(cardRate: 1 - 11.67e-6)
        var t = 3.0
        _ = s.tick(at: t); t += 1
        _ = s.tick(at: t); t += 1
        var worst = 0.0
        for i in 0..<120 {
            if i == 30 { s.cardRate = 1 + 115e-6 }
            if i == 60 { s.cardRate = 1 - 125e-6 }
            if case .write(let w) = s.tick(at: t) { worst = max(worst, abs(w.error)) } else { XCTFail("no write") }
            t += 1
        }
        XCTAssertLessThan(worst, 0.0005)
    }

    func testPausedClockIsNeverWritten() {
        var s = Sim(cardRate: 1 - 11.67e-6)
        _ = s.tick(at: 3); _ = s.tick(at: 4)
        guard case .write = s.tick(at: 5) else { return XCTFail("not locked") }
        XCTAssertEqual(s.tick(at: 6, running: false), .idle)
        XCTAssertFalse(s.steering.isLatched)
    }

    func testResumeLatchesAfresh() {
        var s = Sim(cardRate: 1)
        _ = s.tick(at: 3); _ = s.tick(at: 4)
        _ = s.tick(at: 5, running: false)
        s.line = (s.clock(at: 5), 8, 1)                     // resumed at 8, from where it stopped
        XCTAssertEqual(s.tick(at: 9), .wait(.settling))
        guard case .write(let w) = s.tick(at: 10) else { return XCTFail("no latch") }
        XCTAssertEqual(w.latched, .run)
    }

    func testHeldRateStartIsNotLatched() {
        var s = Sim(cardRate: 1)
        s.line = (2, 0, 0)                                  // rate says 1, the clock has not moved
        XCTAssertEqual(s.tick(at: 3), .wait(.settling))
        XCTAssertEqual(s.tick(at: 4), .wait(.settling))
        XCTAssertFalse(s.steering.isLatched)
    }

    func testSeekWhileRunningRelatches() {
        var s = Sim(cardRate: 1 - 11.67e-6)
        _ = s.tick(at: 3); _ = s.tick(at: 4); _ = s.tick(at: 5)
        s.line = (500, 5.5, 1)                              // a seek
        XCTAssertEqual(s.tick(at: 6), .wait(.settling))
        guard case .write(let w) = s.tick(at: 7) else { return XCTFail("no latch") }
        XCTAssertEqual(w.latched, .transport)
        XCTAssertEqual(w.time, s.clock(at: w.host), accuracy: 1e-5, "a latch must not move the clock")
    }

    func testSmallTransportLossStaysOnTheLine() {
        var s = Sim(cardRate: 1)
        _ = s.tick(at: 3); _ = s.tick(at: 4); _ = s.tick(at: 5)
        s.line.time -= 0.003
        guard case .write(let w) = s.tick(at: 6) else { return XCTFail("no write") }
        XCTAssertEqual(w.error, -0.003, accuracy: 1e-5)
        XCTAssertNil(w.latched)
    }

    func testStaleSamplesHold() {
        var s = Sim(cardRate: 1)
        _ = s.tick(at: 3); _ = s.tick(at: 4); _ = s.tick(at: 5)
        let frozen = s.samples
        let d = s.steering.tick(samples: frozen, clock: s.clock(at: 7), clockHost: 7, running: true)
        XCTAssertEqual(d, .wait(.stale))
        XCTAssertTrue(s.steering.isLatched)
    }

    func testCardPositionStepRelatchesOnce() {
        var s = Sim(cardRate: 1)
        _ = s.tick(at: 3); _ = s.tick(at: 4); _ = s.tick(at: 5)
        s.nextHost += 0.012                                 // a reference locking re-times the card: its stamps step
        var latches = 0
        for t in 6...12 { if case .write(let w) = s.tick(at: Double(t)), w.latched != nil { XCTAssertEqual(w.latched, .cardStep); latches += 1 } }
        XCTAssertEqual(latches, 1)
    }

    func testIncredibleRateIsSkipped() {
        var s = Sim(cardRate: 1.05)
        _ = s.tick(at: 3)
        XCTAssertEqual(s.tick(at: 4), .wait(.badRate))
    }

    func testWriteHostIsAlwaysPast() {
        var s = Sim(cardRate: 1)
        for t in 3...20 {
            let now = Double(t) + 0.0001
            if case .write(let w) = s.tick(at: now) { XCTAssertLessThanOrEqual(w.host, now - s.steering.settings.writeAge) }
        }
    }

    func testRingKeepsOrderAcrossWrap() {
        let r = CardClockSampleRing()
        for i in 0..<3000 { r.append(slot: Int64(i), host: Double(i)) }
        let s = r.snapshot()
        XCTAssertEqual(s.count, 1024); XCTAssertEqual(s.first?.slot, 3000 - 1024); XCTAssertEqual(s.last?.slot, 2999)
        r.reset(); XCTAssertTrue(r.snapshot().isEmpty)
    }
}
