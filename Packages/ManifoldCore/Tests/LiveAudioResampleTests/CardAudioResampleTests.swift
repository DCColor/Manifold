//
//  CardAudioResampleTests.swift
//  Stage 2 (docs/CARD_CLOCK_FINDINGS.md §10.27): the file arm's resampler box.
//

import XCTest
import CoreMedia
@testable import LiveAudioResample

final class CardAudioResampleTests: XCTestCase {
    typealias T = LiveAudioResampleStageTests

    /// Inactive: the buffer itself, untouched, and the content map is the identity.
    func testInactivePassesThrough() {
        let fmt = T.makeFormat(rate: 48000, channels: 2)
        let box = CardAudioResample(axisOffset: 0, reportsWindows: false, log: nil)
        let sb = T.makeInput(tick: 48000, frames: 960, format: fmt)
        let out = box.process(sb)
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0] === sb)
        XCTAssertEqual(box.contentTime(atOutputTime: 1.5), 1.5)
        XCTAssertEqual(box.rho, 1)
    }

    /// Active at ρ 1: output tick k carries input sample k (the stage's own rule), and the map is the identity.
    func testActiveAtUnityIsIdentity() {
        let fmt = T.makeFormat(rate: 48000, channels: 2)
        let box = CardAudioResample(axisOffset: 0, reportsWindows: false, log: nil)
        box.activate()
        var outs: [CMSampleBuffer] = []
        for k in 0..<20 { outs += box.process(T.makeInput(tick: 48000 + Int64(k) * 960, frames: 960, format: fmt)) }
        XCTAssertFalse(outs.isEmpty)
        let first = CMSampleBufferGetPresentationTimeStamp(outs[0])
        XCTAssertEqual(first.value, 48000 - 32)   // the primer, so input sample k lands on tick k
        XCTAssertEqual(box.contentTime(atOutputTime: 1.1), 1.1, accuracy: 1e-9)
        XCTAssertEqual(box.outputTime(atContentTime: 1.1), 1.1, accuracy: 1e-9)
    }

    /// An axis offset moves every output pts by the offset, and the content map takes it off again.
    func testAxisOffset() {
        let fmt = T.makeFormat(rate: 48000, channels: 2)
        let box = CardAudioResample(axisOffset: 0.010, reportsWindows: false, log: nil)
        box.activate()
        var outs: [CMSampleBuffer] = []
        for k in 0..<20 { outs += box.process(T.makeInput(tick: 48000 + Int64(k) * 960, frames: 960, format: fmt)) }
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(outs[0]).value, 48000 + 480 - 32)
        XCTAssertEqual(box.contentTime(atOutputTime: 1.110), 1.100, accuracy: 1e-9)
        XCTAssertEqual(box.outputTime(atContentTime: 1.100), 1.110, accuracy: 1e-9)
    }

    /// The steering writes ρ onto the active stage; an integrator reset puts it back at 1.
    func testSteeringWritesRho() {
        let box = CardAudioResample(axisOffset: 0, reportsWindows: false, log: nil)
        box.activate()
        var steer = CardAudioSteering()
        for _ in 0..<50 { steer.step(error: 0.001, dt: 0.1, resample: box) }   // the Mac's sound 1 ms ahead: consume slower
        XCTAssertLessThan(box.rho, 1)
        XCTAssertEqual(box.rho, steer.state.rho, accuracy: 1e-9)
        steer.resetIntegrator(resample: box)
        XCTAssertEqual(box.rho, 1)
    }
}
