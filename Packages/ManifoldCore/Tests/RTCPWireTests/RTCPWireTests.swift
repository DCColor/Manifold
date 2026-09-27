//
//  RTCPWireTests.swift
//  RTCPWireTests
//
//  Step 4e-1: the video track's own RTCP. Every expected byte string below is written out by hand
//  from the RFC field diagrams, not produced by the code under test — a test that re-derives its
//  expectation with the same arithmetic as the encoder proves nothing.
//

import XCTest
import RTCPWire

final class RTCPWireTests: XCTestCase {

    // MARK: - PLI (RFC 4585 §6.1, §6.3.1)

    func testPliByteLayout() {
        var out = [UInt8](repeating: 0xEE, count: 16)
        let n = ManifoldRTCPBuildPli(&out, out.count, 0x1122_3344, 0x5566_7788)
        XCTAssertEqual(n, 12)
        XCTAssertEqual(Array(out[0..<12]), [
            0x81, 0xCE, 0x00, 0x02,     // V=2 P=0 FMT=1 | PT=206 | length 2 (three words minus one)
            0x11, 0x22, 0x33, 0x44,     // SSRC of packet sender
            0x55, 0x66, 0x77, 0x88,     // SSRC of media source
        ])
        XCTAssertEqual(Array(out[12...]), [0xEE, 0xEE, 0xEE, 0xEE], "wrote past the packet")
    }

    func testPliRefusesShortBuffer() {
        var out = [UInt8](repeating: 0, count: 11)
        XCTAssertEqual(ManifoldRTCPBuildPli(&out, out.count, 1, 2), 0)
    }

    // MARK: - Receiver Report (RFC 3550 §6.4.1, §6.4.2)

    func testReceiverReportByteLayout() {
        var block = ManifoldRTCPReportBlock()
        block.ssrc = 0x0102_0304
        block.fractionLost = 0x40               // 64/256 = 25 %
        block.cumulativeLost = 5
        block.extendedHighestSeq = 0x0001_FFFE  // one wrap, seq 65534
        block.jitter = 0x10
        block.lastSR = 0xABCD_1234
        block.delaySinceLastSR = 0x0001_0000    // exactly 1 s
        var out = [UInt8](repeating: 0xEE, count: 36)
        let n = ManifoldRTCPBuildReceiverReport(&out, out.count, 0xDEAD_BEEF, &block)
        XCTAssertEqual(n, 32)
        XCTAssertEqual(Array(out[0..<32]), [
            0x81, 0xC9, 0x00, 0x07,     // V=2 P=0 RC=1 | PT=201 | length 7 (eight words minus one)
            0xDE, 0xAD, 0xBE, 0xEF,     // SSRC of packet sender
            0x01, 0x02, 0x03, 0x04,     // SSRC_1
            0x40, 0x00, 0x00, 0x05,     // fraction lost | cumulative lost (24-bit)
            0x00, 0x01, 0xFF, 0xFE,     // extended highest sequence number
            0x00, 0x00, 0x00, 0x10,     // interarrival jitter
            0xAB, 0xCD, 0x12, 0x34,     // LSR
            0x00, 0x01, 0x00, 0x00,     // DLSR
        ])
        XCTAssertEqual(Array(out[32...]), [0xEE, 0xEE, 0xEE, 0xEE], "wrote past the packet")
    }

    /// §6.4.1: cumulative lost is SIGNED 24-bit and "may be negative if there are duplicates".
    /// Out-of-range values clamp; they must never wrap into the opposite sign.
    func testCumulativeLostIsSigned24BitAndClamps() {
        func lostField(_ v: Int32) -> [UInt8] {
            var block = ManifoldRTCPReportBlock()
            block.cumulativeLost = v
            block.fractionLost = 0x01
            var out = [UInt8](repeating: 0, count: 32)
            XCTAssertEqual(ManifoldRTCPBuildReceiverReport(&out, out.count, 0, &block), 32)
            return Array(out[12..<16])
        }
        XCTAssertEqual(lostField(-1),         [0x01, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(lostField(0x7F_FFFF),  [0x01, 0x7F, 0xFF, 0xFF])
        XCTAssertEqual(lostField(0x100_0000), [0x01, 0x7F, 0xFF, 0xFF], "must clamp, not wrap")
        XCTAssertEqual(lostField(-0x80_0000), [0x01, 0x80, 0x00, 0x00])
        XCTAssertEqual(lostField(-0x90_0000), [0x01, 0x80, 0x00, 0x00], "must clamp, not wrap")
    }

    /// RFC 3550 A.3: `(lost_interval << 8) / expected_interval`, 0 when nothing was lost.
    func testFractionLost() {
        XCTAssertEqual(ManifoldRTCPFractionLost(100, 25), 64)
        XCTAssertEqual(ManifoldRTCPFractionLost(100, 0), 0)
        XCTAssertEqual(ManifoldRTCPFractionLost(100, -3), 0, "duplicates must not report as loss")
        XCTAssertEqual(ManifoldRTCPFractionLost(0, 5), 0, "an empty interval reports nothing")
        XCTAssertEqual(ManifoldRTCPFractionLost(3, 3), 255, "total loss saturates the 8-bit field")
    }

    /// LSR is the middle 32 bits of the 64-bit NTP; DLSR is in 1/65536 s.
    func testLsrAndDlsrUnits() {
        XCTAssertEqual(ManifoldRTCPCompactNTP(0x1122_3344_5566_7788), 0x3344_5566)
        XCTAssertEqual(ManifoldRTCPDelaySinceSR(1_500_000_000), 0x0001_8000)   // 1.5 s
        XCTAssertEqual(ManifoldRTCPDelaySinceSR(0), 0)
        XCTAssertEqual(ManifoldRTCPDelaySinceSR(1_000_000), 65, "1 ms = 65.536 units, truncated")
        XCTAssertEqual(ManifoldRTCPDelaySinceSR(UInt64(1) << 62), UInt32.max, "saturates")
    }

    // MARK: - Interarrival jitter (RFC 3550 A.8)

    func testJitterIsZeroForConstantTransit() {
        var j = ManifoldRTCPJitter()
        for k in 0..<50 {
            let ts = UInt32(k * 3000)
            ManifoldRTCPJitterUpdate(&j, ts &+ 1234, ts)
        }
        XCTAssertEqual(ManifoldRTCPJitterValue(&j), 0)
    }

    /// A.8's integer recurrence, stepped by hand: J(Q4) += d − ((J + 8) >> 4).
    func testJitterRecurrenceByHand() {
        var j = ManifoldRTCPJitter()
        ManifoldRTCPJitterUpdate(&j, 1000, 0)           // seeds transit = 1000
        XCTAssertEqual(j.jitterQ4, 0)
        ManifoldRTCPJitterUpdate(&j, 4016, 3000)        // transit 1016, d = 16 → 0 + 16 − 0 = 16
        XCTAssertEqual(j.jitterQ4, 16)
        ManifoldRTCPJitterUpdate(&j, 7000, 6000)        // transit 1000, d = 16 → 16 + 16 − 1 = 31
        XCTAssertEqual(j.jitterQ4, 31)
        XCTAssertEqual(ManifoldRTCPJitterValue(&j), 1)
    }

    /// Both clocks wrap at 2^32; the transit difference must not.
    func testJitterAcrossTimestampWrap() {
        var j = ManifoldRTCPJitter()
        ManifoldRTCPJitterUpdate(&j, 100, 0xFFFF_FF00)
        ManifoldRTCPJitterUpdate(&j, 100 &+ 0x200, 0x0000_0100)   // same transit across the wrap
        XCTAssertEqual(j.jitterQ4, 0)
    }

    // MARK: - SR selection by SSRC (RFC 3550 §6.1, §6.4.1, §6.5)

    private static let audioSSRC: UInt32 = 0xA0A0_A0A0
    private static let videoSSRC: UInt32 = 0x0B0B_0B0B

    private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }

    /// SR with no report blocks: header, sender SSRC, NTP (2 words), RTP, packet count, octet count.
    private static func sr(ssrc: UInt32, ntpHi: UInt32, ntpLo: UInt32, rtp: UInt32,
                           packets: UInt32, octets: UInt32) -> [UInt8] {
        [0x80, 200, 0x00, 0x06] + be32(ssrc) + be32(ntpHi) + be32(ntpLo) + be32(rtp)
            + be32(packets) + be32(octets)
    }

    /// Two SDES chunks, each one CNAME item, NUL-terminated and padded to 32 bits.
    private static func sdes(_ chunks: [(UInt32, String)]) -> [UInt8] {
        var body: [UInt8] = []
        for (ssrc, cname) in chunks {
            var chunk = be32(ssrc) + [1, UInt8(cname.utf8.count)] + Array(cname.utf8) + [0]
            while chunk.count % 4 != 0 { chunk.append(0) }
            body += chunk
        }
        let words = UInt16((4 + body.count) / 4 - 1)
        return [0x80 | UInt8(chunks.count), 202, UInt8(words >> 8), UInt8(words & 0xFF)] + body
    }

    /// The compound packet BUNDLE delivers whole to both tracks: audio's SR FIRST, then video's,
    /// then SDES for both. "First SR wins" would hand video the audio mapping.
    private static let compound: [UInt8] =
        sr(ssrc: audioSSRC, ntpHi: 0xE9F0_0001, ntpLo: 0x8000_0000, rtp: 48_000,
           packets: 50, octets: 5_000)
        + sr(ssrc: videoSSRC, ntpHi: 0xE9F0_0002, ntpLo: 0x4000_0000, rtp: 90_000,
             packets: 70, octets: 70_000)
        + sdes([(audioSSRC, "audio-cname"), (videoSSRC, "video@cname")])

    func testSelectsVideoSRBySSRCNotPosition() {
        var info = ManifoldRTCPSenderReport()
        let found = Self.compound.withUnsafeBufferPointer {
            ManifoldRTCPFindSenderReport($0.baseAddress, $0.count, Self.videoSSRC, &info)
        }
        XCTAssertTrue(found)
        XCTAssertEqual(info.ssrc, Self.videoSSRC)
        XCTAssertEqual(info.ntp, 0xE9F0_0002_4000_0000)
        XCTAssertEqual(info.rtp, 90_000)
        XCTAssertEqual(info.senderPacketCount, 70)
        XCTAssertEqual(info.senderOctetCount, 70_000)
        XCTAssertEqual(info.senderReportsSeen, 2)
        XCTAssertTrue(info.haveCNAME)
        XCTAssertEqual(cname(info), "video@cname", "CNAME must come from the SAME SSRC's chunk")
    }

    func testSelectsAudioSRBySSRC() {
        var info = ManifoldRTCPSenderReport()
        let found = Self.compound.withUnsafeBufferPointer {
            ManifoldRTCPFindSenderReport($0.baseAddress, $0.count, Self.audioSSRC, &info)
        }
        XCTAssertTrue(found)
        XCTAssertEqual(info.ntp, 0xE9F0_0001_8000_0000)
        XCTAssertEqual(info.rtp, 48_000)
        XCTAssertEqual(cname(info), "audio-cname")
    }

    func testNoMatchingSSRCReportsNothingButCountsSRs() {
        var info = ManifoldRTCPSenderReport()
        let found = Self.compound.withUnsafeBufferPointer {
            ManifoldRTCPFindSenderReport($0.baseAddress, $0.count, 0x1234_5678, &info)
        }
        XCTAssertFalse(found)
        XCTAssertFalse(info.haveSR)
        XCTAssertFalse(info.haveCNAME)
        XCTAssertEqual(info.senderReportsSeen, 2)
    }

    /// A reduced-size (RFC 5506) packet: the SR alone, no SDES. Legal, and still selected.
    func testReducedSizeSRWithoutSDES() {
        let packet = Self.sr(ssrc: Self.videoSSRC, ntpHi: 1, ntpLo: 2, rtp: 3, packets: 4, octets: 5)
        var info = ManifoldRTCPSenderReport()
        let found = packet.withUnsafeBufferPointer {
            ManifoldRTCPFindSenderReport($0.baseAddress, $0.count, Self.videoSSRC, &info)
        }
        XCTAssertTrue(found)
        XCTAssertEqual(info.ntp, 0x0000_0001_0000_0002)
        XCTAssertFalse(info.haveCNAME)
    }

    /// A length field that overruns the buffer stops the walk; nothing past it is trusted.
    func testTruncatedPacketIsNotRead() {
        var packet = Self.compound
        packet.removeLast(Self.compound.count - 40)   // mid-way through the video SR
        var info = ManifoldRTCPSenderReport()
        let found = packet.withUnsafeBufferPointer {
            ManifoldRTCPFindSenderReport($0.baseAddress, $0.count, Self.videoSSRC, &info)
        }
        XCTAssertFalse(found)
        XCTAssertEqual(info.senderReportsSeen, 1)
    }

    private func cname(_ info: ManifoldRTCPSenderReport) -> String {
        var copy = info.cname
        return withUnsafeBytes(of: &copy) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }
}
