import XCTest
@testable import AudioFileInfo

final class BroadcastWaveTests: XCTestCase {

    // MARK: Building files

    private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
    private func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }

    private func chunk(_ id: String, _ body: [UInt8], statedSize: UInt32? = nil) -> [UInt8] {
        Array(id.utf8) + le32(statedSize ?? UInt32(body.count)) + body + (body.count % 2 == 1 ? [0] : [])
    }

    private func fmt(rate: UInt32 = 48_000) -> [UInt8] {
        chunk("fmt ", [1, 0, 2, 0] + le32(rate) + le32(rate * 6) + [6, 0, 24, 0])
    }

    private func bext(reference: UInt64, date: String = "2026-11-04", time: String = "12:30:15") -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 602)
        b.replaceSubrange(320..<330, with: Array(date.utf8))
        b.replaceSubrange(330..<338, with: Array(time.utf8))
        b.replaceSubrange(338..<346, with: le64(reference))
        return b
    }

    private func file(_ chunks: [UInt8]..., form: String = "RIFF") -> [UInt8] {
        let body = Array("WAVE".utf8) + chunks.flatMap { $0 }
        return Array(form.utf8) + le32(UInt32(body.count)) + body
    }

    private func parse(_ bytes: [UInt8]) -> BroadcastWaveInfo? {
        BroadcastWaveReader.parse(size: UInt64(bytes.count)) { offset, count in
            guard offset < UInt64(bytes.count) else { return Data() }
            let start = Int(offset)
            return Data(bytes[start..<min(start + count, bytes.count)])
        }
    }

    private func ixml(rate: String, flag: String = "NDF") -> [UInt8] {
        chunk("iXML", Array("""
        <?xml version="1.0"?><BWFXML><SPEED><TIMECODE_RATE>\(rate)</TIMECODE_RATE>\
        <TIMECODE_FLAG>\(flag)</TIMECODE_FLAG></SPEED></BWFXML>
        """.utf8))
    }

    // MARK: Parsing

    func testBextOnly() throws {
        let info = try XCTUnwrap(parse(file(fmt(), chunk("bext", bext(reference: 172_800_000)), chunk("data", [0, 0]))))
        XCTAssertEqual(info.timeReference, 172_800_000)
        XCTAssertEqual(info.originationDate, "2026-11-04")
        XCTAssertEqual(info.originationTime, "12:30:15")
        XCTAssertEqual(info.sampleRate, 48_000)
        XCTAssertNil(info.timecodeRate)
    }

    func testTimeReferenceUsesTheHighWord() throws {
        let reference: UInt64 = 0x1_0000_0002
        let info = try XCTUnwrap(parse(file(chunk("bext", bext(reference: reference)))))
        XCTAssertEqual(info.timeReference, reference)
    }

    func testBextAndIXML() throws {
        let info = try XCTUnwrap(parse(file(fmt(), chunk("bext", bext(reference: 1)), ixml(rate: "24000/1001"))))
        XCTAssertEqual(info.timecodeRate, TimecodeRate(numerator: 24_000, denominator: 1001))
        XCTAssertFalse(info.dropFrame)
    }

    func testChunksAfterAnOddSizedChunkAreFound() throws {
        let info = try XCTUnwrap(parse(file(chunk("junk", [1, 2, 3]), chunk("bext", bext(reference: 9)))))
        XCTAssertEqual(info.timeReference, 9)
    }

    func testPlainWaveHasNoRows() throws {
        let info = try XCTUnwrap(parse(file(fmt(), chunk("data", [0, 0]))))
        XCTAssertTrue(info.isEmpty)
        XCTAssertTrue(info.inspectorRows(fallbackSampleRate: 48_000).isEmpty)
    }

    func testNotAWave() {
        XCTAssertNil(parse(Array("FORM".utf8) + le32(4) + Array("AIFF".utf8)))
        XCTAssertNil(parse([1, 2, 3]))
    }

    func testTruncatedBextKeepsWhatItHas() throws {
        // The file ends inside the stamp: the date is whole, TimeReference never arrives.
        let body = Array(bext(reference: 5).prefix(332))
        let info = try XCTUnwrap(parse(file(fmt(), chunk("bext", body, statedSize: 602))))
        XCTAssertEqual(info.originationDate, "2026-11-04")
        XCTAssertNil(info.timeReference)
    }

    func testChunkSizePastTheEndOfTheFileEndsTheWalk() throws {
        let info = try XCTUnwrap(parse(file(fmt(), chunk("data", [0, 0], statedSize: 0xFFFF_FFF0), chunk("bext", bext(reference: 1)))))
        XCTAssertEqual(info.sampleRate, 48_000)
        XCTAssertNil(info.timeReference)
    }

    func testRF64FollowsTheDataSizeInDS64() throws {
        let dataBody: [UInt8] = [0, 0, 0, 0]
        let ds64 = chunk("ds64", le64(0) + le64(UInt64(dataBody.count)) + le64(0) + le32(0))
        let bytes = file(ds64, fmt(), chunk("data", dataBody, statedSize: 0xFFFF_FFFF), chunk("bext", bext(reference: 77)), form: "RF64")
        XCTAssertEqual(parse(bytes)?.timeReference, 77)
    }

    func testDataOfFFFFFFFFInPlainRIFFIsNotExpanded() throws {
        let ds64 = chunk("ds64", le64(0) + le64(4) + le64(0) + le32(0))
        let bytes = file(ds64, chunk("data", [0, 0, 0, 0], statedSize: 0xFFFF_FFFF), chunk("bext", bext(reference: 77)))
        XCTAssertNil(parse(bytes)?.timeReference)
    }

    func testRateForms() {
        XCTAssertEqual(TimecodeRate(iXML: " 25/1 "), TimecodeRate(numerator: 25, denominator: 1))
        XCTAssertEqual(TimecodeRate(iXML: "30"), TimecodeRate(numerator: 30, denominator: 1))
        XCTAssertNil(TimecodeRate(iXML: "23.976"))
        XCTAssertNil(TimecodeRate(iXML: "25/0"))
        XCTAssertNil(TimecodeRate(iXML: "/"))
        XCTAssertNil(TimecodeRate(iXML: ""))
    }

    // MARK: Rows

    func testTimeReferenceRowWhenNoRateIsStated() throws {
        var info = BroadcastWaveInfo()
        info.sampleRate = 48_000
        info.timeReference = 172_800_000 + 24_000     // one hour and 500 ms
        let rows = info.inspectorRows(fallbackSampleRate: 0)
        XCTAssertEqual(rows.map(\.label), ["Time Reference"])
        XCTAssertEqual(rows.first?.value, "01:00:00.500")
    }

    func testTimecodeRowWhenARateIsStated() throws {
        var info = BroadcastWaveInfo()
        info.sampleRate = 48_000
        info.timeReference = 172_800_000
        info.timecodeRate = TimecodeRate(numerator: 25, denominator: 1)
        let rows = info.inspectorRows(fallbackSampleRate: 0)
        XCTAssertEqual(rows.map(\.label), ["Timecode"])
        XCTAssertEqual(rows.first?.value, "01:00:00:00 @ 25")
    }

    func testFallbackSampleRate() {
        var info = BroadcastWaveInfo()
        info.timeReference = 96_000
        XCTAssertEqual(info.inspectorRows(fallbackSampleRate: 96_000).first?.value, "00:00:01.000")
        XCTAssertTrue(info.inspectorRows(fallbackSampleRate: 0).isEmpty, "no rate means no time")
    }

    func testOriginationRow() {
        var info = BroadcastWaveInfo()
        info.originationDate = "2026-11-04"
        info.originationTime = "12:30:15"
        XCTAssertEqual(info.inspectorRows(fallbackSampleRate: 48_000).first?.value, "2026-11-04 12:30:15")
    }

    func testNTSCRateCountsFramesAtTheRealRate() {
        let rate = TimecodeRate(numerator: 24_000, denominator: 1001)!
        // 86,400 frames at 23.976 is 01:00:00:00 on the counter and 3,603.6 s on the clock.
        XCTAssertEqual(BroadcastWaveInfo.timecode(samples: 172_972_800, sampleRate: 48_000, rate: rate, dropFrame: false),
                       "01:00:00:00")
        XCTAssertEqual(BroadcastWaveInfo.rateText(rate), "23.976")
    }

    func testDropFrame() {
        let rate = TimecodeRate(numerator: 30_000, denominator: 1001)!
        func at(frame: UInt64) -> String? {
            let samples = UInt64((Double(frame) * 1001 / 30_000 * 48_000).rounded())
            return BroadcastWaveInfo.timecode(samples: samples, sampleRate: 48_000, rate: rate, dropFrame: true)
        }
        XCTAssertEqual(at(frame: 1799), "00:00:59;29")
        XCTAssertEqual(at(frame: 1800), "00:01:00;02")
        XCTAssertEqual(at(frame: 17_982), "00:10:00;00")
        XCTAssertEqual(at(frame: 107_892), "01:00:00;00")
        XCTAssertEqual(BroadcastWaveInfo.rateText(rate), "29.97")
    }

    func testDropFrameFlagIsIgnoredAtARateThatCannotDrop() {
        let rate = TimecodeRate(numerator: 25, denominator: 1)!
        XCTAssertEqual(BroadcastWaveInfo.timecode(samples: 48_000, sampleRate: 48_000, rate: rate, dropFrame: true), "00:00:01:00")
    }

    func testAbsurdCountsDoNotTrap() {
        XCTAssertNil(BroadcastWaveInfo.clockTime(samples: .max, sampleRate: 1))
        let rate = TimecodeRate(numerator: 60, denominator: 1)!
        XCTAssertNil(BroadcastWaveInfo.timecode(samples: .max, sampleRate: 1, rate: rate, dropFrame: false))
    }

    // MARK: Card text

    func testFormatLine() {
        XCTAssertEqual(AudioCardText.format(container: "WAV", codec: "PCM", bitDepth: 24, isFloat: false), "WAV · 24-bit PCM")
        XCTAssertEqual(AudioCardText.format(container: "WAV", codec: "PCM", bitDepth: 32, isFloat: true), "WAV · 32-bit float")
        XCTAssertEqual(AudioCardText.format(container: "M4A", codec: "AAC", bitDepth: 0, isFloat: false), "M4A · AAC")
        XCTAssertEqual(AudioCardText.format(container: "MP3", codec: "MP3", bitDepth: 0, isFloat: false), "MP3")
        XCTAssertEqual(AudioCardText.format(container: "AIF", codec: "—", bitDepth: 0, isFloat: false), "AIF")
    }

    func testChannelsLine() {
        XCTAssertEqual(AudioCardText.channels(count: 1, declaredLayout: nil), "1 channel")
        XCTAssertEqual(AudioCardText.channels(count: 2, declaredLayout: "Stereo"), "2 channels · Stereo")
        XCTAssertEqual(AudioCardText.channels(count: 6, declaredLayout: "—"), "6 channels")
    }

    func testSampleRateLine() {
        XCTAssertEqual(AudioCardText.sampleRate(44_100), "44.1 kHz")
        XCTAssertEqual(AudioCardText.sampleRate(48_000), "48 kHz")
        XCTAssertEqual(AudioCardText.sampleRate(22_050), "22.05 kHz")
        XCTAssertEqual(AudioCardText.sampleRate(0), "—")
    }

    func testDurationLine() {
        XCTAssertEqual(AudioCardText.duration(3.25), "0:03.250")
        XCTAssertEqual(AudioCardText.duration(3723.456), "1:02:03.456")
        XCTAssertEqual(AudioCardText.duration(.nan), "—")
    }
}
