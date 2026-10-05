import XCTest
import CoreMedia
import AudioToolbox
@testable import FileAudioLookahead

/// `TapLookaheadPump` (docs/AUDIO_RESAMPLER_DESIGN.md §19.12), driven the way FrameEngine drives it:
/// a renderer that accepts up to a fixed queue, a decoder of fixed-size buffers, a tap that records
/// ingests and can be reset, and an audio session token that a seek bumps.
final class TapLookaheadPumpTests: XCTestCase {

    struct Buf: Equatable { let pts: Double; let frames: Int }
    static let rate = 48_000.0
    static func dur(_ b: Buf) -> Double { Double(b.frames) / rate }

    /// A decoder of `frames`-sized buffers from `start`, ending at `end` (exclusive).
    final class Decoder {
        var next: Double; let frames: Int; let end: Double
        var decoded = 0
        var onDecode: (() -> Void)?
        init(start: Double, frames: Int = 8192, end: Double = .infinity) {
            next = start; self.frames = frames; self.end = end
        }
        func read() -> Buf? {
            guard next < end else { return nil }
            let b = Buf(pts: next, frames: frames)
            next += Double(frames) / TapLookaheadPumpTests.rate
            decoded += 1
            onDecode?()
            return b
        }
    }

    /// The renderer: ready while its queue (enqueued minus played) is under `capacity` seconds.
    final class Renderer {
        var enqueued: [Buf] = []; var played = 0.0; let capacity: Double
        init(capacity: Double) { self.capacity = capacity }
        var queuedEnd: Double { enqueued.last.map { $0.pts + dur($0) } ?? played }
        var isReady: Bool { queuedEnd - played < capacity }
        func flush() { enqueued.removeAll() }
    }

    /// The tap, as far as the pumps see it: ingest, reset, and what it holds.
    final class Tap {
        var held: [Buf] = []
        var head: Double? { held.last.map { $0.pts + dur($0) } }
        func ingest(_ b: Buf) { held.append(b) }
        func reset() { held.removeAll() }
    }

    final class Token { var value = 0 }

    @discardableResult
    func wake(_ pump: TapLookaheadPump<Buf>, _ r: Renderer, _ d: Decoder, _ tap: Tap,
              _ token: Token, mine: Int) -> TapLookaheadPump<Buf>.Outcome {
        pump.service(isReady: { r.isReady }, isCurrent: { token.value == mine },
                     next: { d.read() }, ingest: { tap.ingest($0) }, enqueue: { r.enqueued.append($0) })
    }

    func makePump() -> TapLookaheadPump<Buf> { TapLookaheadPump<Buf>(duration: Self.dur) }

    // MARK: - The renderer's sequence is unchanged; the tap runs ahead of it

    func testRendererGetsTheSameSequenceAndTheTapLeadsByTheLookahead() {
        let r = Renderer(capacity: 0.9), d = Decoder(start: 0), tap = Tap(), token = Token()
        let pump = makePump()
        for _ in 0..<20 {
            XCTAssertEqual(wake(pump, r, d, tap, token, mine: 0), .waiting)
            // The tap holds everything the renderer has, in the same order, plus the look-ahead.
            XCTAssertEqual(Array(tap.held.prefix(r.enqueued.count)), r.enqueued)
            let lead = tap.head! - r.queuedEnd
            XCTAssertGreaterThanOrEqual(lead, TapLookahead.seconds - 1e-9)
            XCTAssertLessThan(lead, TapLookahead.seconds + Self.dur(Buf(pts: 0, frames: 8192)))
            r.played += 1.0      // the muted renderer's 1 s refill timer
        }
        // Contiguous, each buffer once: nothing skipped, nothing duplicated.
        for (a, b) in zip(r.enqueued, r.enqueued.dropFirst()) {
            XCTAssertEqual(b.pts, a.pts + Self.dur(a), accuracy: 1e-9)
        }
        XCTAssertEqual(tap.held.count, d.decoded)
    }

    func testTheTapNeverDrainsPastTheRendererPlusLookaheadWhenTheRendererStarves() {
        // The §19.12 failure: the renderer drains to the playhead (−150 ms) before its next wake.
        // The tap's head must still be ≥ lookahead − 150 ms past the playhead at every wake.
        let r = Renderer(capacity: 0.85), d = Decoder(start: 0), tap = Tap(), token = Token()
        let pump = makePump()
        wake(pump, r, d, tap, token, mine: 0)
        for _ in 0..<30 {
            r.played = r.queuedEnd + 0.150      // drained 150 ms past its own queue
            XCTAssertGreaterThanOrEqual(tap.head! - r.played, TapLookahead.seconds - 0.150 - 1e-9)
            wake(pump, r, d, tap, token, mine: 0)
        }
    }

    // MARK: - Seek: no stale look-ahead audio reaches the tap or the renderer

    func testSeekRetiresTheHeldLookaheadAndTheNewArmStartsClean() {
        let r = Renderer(capacity: 0.9), tap = Tap(), token = Token()
        let dA = Decoder(start: 10.0)
        let armA = makePump()
        XCTAssertEqual(wake(armA, r, dA, tap, token, mine: 0), .waiting)
        XCTAssertGreaterThan(armA.heldCount, 0, "arm A holds look-ahead buffers at the seek")

        // FrameEngine.teardownAudioReading(): bump the token, flush the renderer, reset the tap.
        token.value += 1
        r.flush(); r.played = 30.0
        tap.reset()

        // A's block fires once more after the teardown (a callback already queued on the pump).
        let decodedBefore = dA.decoded
        XCTAssertEqual(wake(armA, r, dA, tap, token, mine: 0), .retired)
        XCTAssertEqual(armA.heldCount, 0)
        XCTAssertEqual(armA.heldSeconds, 0)
        XCTAssertEqual(dA.decoded, decodedBefore, "a retired arm decodes nothing")
        XCTAssertTrue(tap.held.isEmpty, "a retired arm ingests nothing")
        XCTAssertTrue(r.enqueued.isEmpty, "a retired arm enqueues nothing — its held buffers are dropped")

        // The new arm at the seek target: the tap holds only its audio, from its first buffer.
        let dB = Decoder(start: 30.0)
        let armB = makePump()
        XCTAssertEqual(armB.heldCount, 0)
        XCTAssertEqual(wake(armB, r, dB, tap, token, mine: 1), .waiting)
        XCTAssertEqual(tap.held.first?.pts, 30.0)
        XCTAssertTrue(tap.held.allSatisfy { $0.pts >= 30.0 })
        XCTAssertTrue(r.enqueued.allSatisfy { $0.pts >= 30.0 })
    }

    func testADecodeInFlightAtTheSeekIsNotIngested() {
        // The teardown runs on the main thread while the pump is inside `next()`: the buffer that
        // decode returns belongs to the retired arm and must not land in the freshly reset tap.
        let r = Renderer(capacity: 0.9), tap = Tap(), token = Token()
        let d = Decoder(start: 0)
        let pump = makePump()
        wake(pump, r, d, tap, token, mine: 0)
        r.played = r.queuedEnd                  // the renderer wants more
        d.onDecode = { token.value += 1; tap.reset() }   // the seek lands mid-decode
        XCTAssertEqual(wake(pump, r, d, tap, token, mine: 0), .retired)
        XCTAssertTrue(tap.held.isEmpty)
        XCTAssertEqual(pump.heldCount, 0)
    }

    func testADecodeInFlightDuringTheLookaheadIsNotIngested() {
        let r = Renderer(capacity: 0.9), tap = Tap(), token = Token()
        let d = Decoder(start: 0)
        let pump = makePump()
        // Let the renderer fill, then flip the token on the first look-ahead decode.
        var rendererFull = false
        d.onDecode = { if rendererFull { token.value += 1; tap.reset() } }
        let outcome = pump.service(
            isReady: { let ready = r.isReady; if !ready { rendererFull = true }; return ready },
            isCurrent: { token.value == 0 },
            next: { d.read() }, ingest: { tap.ingest($0) }, enqueue: { r.enqueued.append($0) })
        XCTAssertEqual(outcome, .retired)
        XCTAssertTrue(tap.held.isEmpty)
        XCTAssertEqual(pump.heldCount, 0)
    }

    // MARK: - End of file: the held look-ahead still reaches the renderer

    func testEndOfFileDrainsTheHeldBuffersBeforeEnding() {
        let r = Renderer(capacity: 0.9), tap = Tap(), token = Token()
        let d = Decoder(start: 0, end: 2.0)
        let pump = makePump()
        var outcome = TapLookaheadPump<Buf>.Outcome.waiting
        var wakes = 0
        while outcome == .waiting && wakes < 50 {
            outcome = wake(pump, r, d, tap, token, mine: 0)
            r.played = r.queuedEnd
            wakes += 1
        }
        XCTAssertEqual(outcome, .ended)
        XCTAssertEqual(r.enqueued, tap.held, "every decoded buffer reached the renderer, in order")
        XCTAssertGreaterThanOrEqual(r.queuedEnd, 2.0 - 1e-9)
        XCTAssertEqual(pump.heldCount, 0)
    }

    func testDurationOfAPCMSampleBufferIsFramesOverRate() throws {
        // The pumps size the look-ahead by sample count, not by a container duration.
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                                      magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                                      formatDescriptionOut: &fmt), noErr)
        let frames = 8192
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: frames * 8,
                                                          blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                          dataLength: frames * 8, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                          blockBufferOut: &block), noErr)
        var sb: CMSampleBuffer?
        XCTAssertEqual(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: fmt!, sampleCount: frames,
            presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sb), noErr)
        XCTAssertEqual(TapLookahead.duration(of: try XCTUnwrap(sb)), 8192.0 / 48_000, accuracy: 1e-12)
    }
}
