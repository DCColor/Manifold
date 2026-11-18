import XCTest
@testable import Markers

/// Stage 4 (docs/CHAPTER_MARKERS_PLAN.md §13, D-C15, D-C17): the start-timecode precedence, the QuickTime user-data and
/// XMP readers on synthetic bytes, the override's availability per source, and the basis every marker reader uses.
final class StartTimecodeTests: XCTestCase {

    static let r2398 = 24000.0 / 1001, r2997 = 30000.0 / 1001, r5994 = 60000.0 / 1001

    private func tc(_ label: String, _ fps: Double, _ source: StartTimecodeSource) -> StartTimecode {
        StartTimecode(label: label, fps: fps, source: source)!
    }

    // MARK: Precedence

    func testEveryCombinationOfTheFourSourcesTakesTheHighestPresent() {
        let all = [tc("10:00:00:00", 25, .tmcd), tc("11:00:00:00", 25, .container), tc("01:00:00:00", 25, .userData),
                   tc("02:00:00:00", 25, .xmp)]
        let order: [StartTimecodeSource] = [.tmcd, .container, .userData, .xmp]
        for mask in 0..<16 {
            let has = (0..<4).map { mask & (1 << $0) != 0 }
            let c = StartTimecodePrecedence.Candidates(tmcd: has[0] ? all[0] : nil, container: has[1] ? all[1] : nil,
                                                       userData: has[2] ? all[2] : nil, xmp: has[3] ? all[3] : nil)
            let first = has.firstIndex(of: true)
            let got = StartTimecodePrecedence.file(c)
            XCTAssertEqual(got?.source, first.map { order[$0] }, "mask \(mask)")
            XCTAssertEqual(got?.frameCount, first.map { all[$0].frameCount }, "mask \(mask)")
            XCTAssertEqual(c.needsMetadata, !has[0] && !has[1], "mask \(mask)")
            // With no override, resolve is the file's own.
            XCTAssertEqual(StartTimecodePrecedence.resolve(c, overrideLabel: nil, rate: 25), got, "mask \(mask)")
        }
    }

    func testACandidateIsStampedWithItsSlotsSource() {
        let wrong = tc("01:00:00:00", 25, .tmcd)
        XCTAssertEqual(StartTimecodePrecedence.file(.init(xmp: wrong))?.source, .xmp)
        XCTAssertEqual(StartTimecodePrecedence.file(.init(userData: wrong))?.source, .userData)
    }

    // MARK: The override (D-C17)

    func testTheOverrideIsAvailableOnlyWithoutATmcdOrContainerTimecode() {
        XCTAssertTrue(StartTimecodePrecedence.overrideApplies(to: nil))
        XCTAssertFalse(StartTimecodePrecedence.overrideApplies(to: .tmcd))
        XCTAssertFalse(StartTimecodePrecedence.overrideApplies(to: .container))
        XCTAssertTrue(StartTimecodePrecedence.overrideApplies(to: .userData))
        XCTAssertTrue(StartTimecodePrecedence.overrideApplies(to: .xmp))
    }

    func testTheOverrideReplacesOnlyAUserDataOrXMPStartOrNone() {
        let all = [tc("10:00:00:00", 25, .tmcd), tc("11:00:00:00", 25, .container), tc("01:00:00:00", 25, .userData),
                   tc("02:00:00:00", 25, .xmp)]
        for mask in 0..<16 {
            let has = (0..<4).map { mask & (1 << $0) != 0 }
            let c = StartTimecodePrecedence.Candidates(tmcd: has[0] ? all[0] : nil, container: has[1] ? all[1] : nil,
                                                       userData: has[2] ? all[2] : nil, xmp: has[3] ? all[3] : nil)
            let got = StartTimecodePrecedence.resolve(c, overrideLabel: "05:00:00:00", rate: 25)
            if has[0] || has[1] {
                XCTAssertEqual(got, StartTimecodePrecedence.file(c), "mask \(mask): a tmcd or container TC is never relabelled")
            } else {
                XCTAssertEqual(got?.source, .override, "mask \(mask)")
                XCTAssertEqual(got?.frameCount, 5 * 3600 * 25, "mask \(mask)")
            }
        }
    }

    func testTheOverrideTakesTheReplacedTimecodesRateAndDropFrame() {
        let df = tc("01:00:00;00", Self.r2997, .userData)
        XCTAssertEqual(df.frameCount, 107_892)
        let o = StartTimecodePrecedence.effective(file: df, overrideLabel: "02:00:00;00", rate: Self.r2997)
        XCTAssertEqual(o?.dropFrame, true)
        XCTAssertEqual(o?.nfr, 30)
        XCTAssertEqual(o?.frameCount, 215_784)
        XCTAssertEqual(o?.label, "02:00:00;00")
    }

    func testWithoutAFileTimecodeTheOverrideIsAtTheFileRateNonDrop() {
        let o = StartTimecodePrecedence.effective(file: nil, overrideLabel: "01:00:00:00", rate: Self.r2997)
        XCTAssertEqual(o, StartTimecode(frameCount: 108_000, nfr: 30, fps: Self.r2997, dropFrame: false, source: .override))
        XCTAssertNil(StartTimecodePrecedence.effective(file: nil, overrideLabel: "01:00:00:00", rate: 0), "no rate")
        XCTAssertNil(StartTimecodePrecedence.effective(file: nil, overrideLabel: nil, rate: 25))
        XCTAssertNil(StartTimecodePrecedence.effective(file: nil, overrideLabel: "  ", rate: 25))
    }

    func testAnOverrideThatIsNotALabelHereIsIgnored() {
        let u = tc("01:00:00:00", Self.r2398, .userData)
        XCTAssertEqual(StartTimecodePrecedence.effective(file: u, overrideLabel: "25:00:00:00", rate: Self.r2398), u)
        XCTAssertEqual(StartTimecodePrecedence.effective(file: u, overrideLabel: "01:00:00:24", rate: Self.r2398), u,
                       "frame 24 does not exist at 23.976")
        XCTAssertNil(StartTimecodePrecedence.effective(file: nil, overrideLabel: "nonsense", rate: 25))
    }

    // MARK: Labels

    func testLabelsAreStrictAndDropFrameOnlyAt2997And5994() {
        XCTAssertEqual(StartTimecode(label: "01:00:00:00", fps: Self.r2398, source: .xmp)?.nfr, 24)
        XCTAssertEqual(StartTimecode(label: "01:00:00;00", fps: Self.r2997, source: .xmp)?.dropFrame, true)
        XCTAssertEqual(StartTimecode(label: "01:00:00;00", fps: Self.r5994, source: .xmp)?.frameCount, 215_784)
        XCTAssertNil(StartTimecode(label: "01:00:00;00", fps: 25, source: .xmp), "no drop-frame at 25")
        XCTAssertNil(StartTimecode(label: "01:00:00;00", fps: Self.r2398, source: .xmp), "no drop-frame at 23.976")
        XCTAssertNil(StartTimecode(label: "00:01:00;00", fps: Self.r2997, source: .xmp), "a label drop-frame skips")
        XCTAssertNil(StartTimecode(label: "00:00:00:25", fps: 25, source: .xmp))
        XCTAssertNil(StartTimecode(label: "01:00:00", fps: 25, source: .xmp))
        XCTAssertNil(StartTimecode(label: "01:00:00:00", fps: 24000, source: .xmp), "outside 1…240 fps")
        XCTAssertNil(StartTimecode(label: "01:00:00:00", fps: 0, source: .xmp))
    }

    // MARK: QuickTime user data

    static func intlText(_ s: String) -> Data {
        let b = Array(s.utf8)
        return Data([UInt8(b.count >> 8), UInt8(b.count & 0xFF), 0, 0] + b)
    }

    static func dataBox(_ s: String) -> Data {
        let b = Array(s.utf8)
        let size = 16 + b.count
        return Data([UInt8(size >> 24), UInt8((size >> 16) & 0xFF), UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)]
                    + Array("data".utf8) + [0, 0, 0, 1, 0, 0, 0, 0] + b)
    }

    func testUserDataAsPremiereWritesIt() {
        // Premiere's three atoms, byte for byte (exiftool -v3 on w1/premiere_ranged_tc1h - h264.mp4).
        let t = StartTimecodeMetadata.userData(tim: Self.intlText("01:00:00:00"), tsc: Self.intlText("24000"),
                                               tsz: Self.intlText("1001"))
        XCTAssertEqual(t, StartTimecode(frameCount: 86_400, nfr: 24, fps: Self.r2398, dropFrame: false, source: .userData))
        XCTAssertEqual(Self.intlText("01:00:00:00"), Data([0x00, 0x0B, 0x00, 0x00]) + Data("01:00:00:00".utf8))
    }

    func testUserDataInADataBox() {
        let t = StartTimecodeMetadata.userData(tim: Self.dataBox("10:00:00:00"), tsc: Self.dataBox("25"), tsz: nil)
        XCTAssertEqual(t?.frameCount, 900_000)
        XCTAssertEqual(t?.fps, 25)
    }

    func testUserDataDropFrameAndOddRates() {
        func ud(_ l: String, _ scale: String, _ size: String) -> StartTimecode? {
            StartTimecodeMetadata.userData(tim: Self.intlText(l), tsc: Self.intlText(scale), tsz: Self.intlText(size))
        }
        XCTAssertEqual(ud("01:00:00;00", "30000", "1001")?.frameCount, 107_892)
        XCTAssertEqual(ud("01:00:00;00", "30000", "1001")?.dropFrame, true)
        XCTAssertEqual(ud("01:00:00;00", "60000", "1001")?.frameCount, 215_784)
        XCTAssertEqual(ud("01:00:00:00", "30000", "1001")?.dropFrame, false)
        XCTAssertEqual(ud("00:00:01:49", "50", "1")?.frameCount, 99)
        XCTAssertEqual(ud("00:00:00:47", "48000", "1001")?.nfr, 48, "47.952")
        XCTAssertNil(ud("00:00:00:48", "48000", "1001"))
        XCTAssertEqual(ud("00:00:00:11", "12", "1")?.frameCount, 11)
        XCTAssertNil(ud("01:00:00;00", "25", "1"), "drop-frame at 25")
    }

    func testUserDataWithoutARateOrReadableTextIsNil() {
        let tim = Self.intlText("01:00:00:00")
        XCTAssertNil(StartTimecodeMetadata.userData(tim: tim, tsc: nil, tsz: Self.intlText("1001")))
        XCTAssertNil(StartTimecodeMetadata.userData(tim: tim, tsc: Self.intlText("0"), tsz: nil))
        XCTAssertNil(StartTimecodeMetadata.userData(tim: tim, tsc: Self.intlText("24000"), tsz: Self.intlText("0")))
        XCTAssertNil(StartTimecodeMetadata.userData(tim: tim, tsc: Self.intlText("24000"), tsz: nil), "24000 fps")
        XCTAssertNil(StartTimecodeMetadata.userData(tim: Data([0, 20, 0, 0]) + Data("01:00".utf8), tsc: Self.intlText("25"), tsz: nil),
                     "a length past the payload")
        XCTAssertNil(StartTimecodeMetadata.userData(tim: Data([0, 4, 0, 0, 0xC3, 0xA9, 0x30, 0x30]), tsc: Self.intlText("25"), tsz: nil),
                     "not ASCII")
        XCTAssertNil(StartTimecodeMetadata.userData(tim: Data([0, 0]), tsc: Self.intlText("25"), tsz: nil))
    }

    // MARK: The box walk (synthetic files)

    static func rawBox(_ type: [UInt8], _ payload: Data) -> Data {
        var d = Data()
        withUnsafeBytes(of: UInt32(8 + payload.count).bigEndian) { d.append(contentsOf: $0) }
        d.append(contentsOf: type)
        return d + payload
    }
    static func box(_ type: String, _ payload: Data) -> Data { rawBox(Array(type.utf8), payload) }
    static let tim: [UInt8] = [0xA9, 0x54, 0x49, 0x4D], tsc: [UInt8] = [0xA9, 0x54, 0x53, 0x43], tsz: [UInt8] = [0xA9, 0x54, 0x53, 0x5A]

    static func premiereUdta(_ label: String = "01:00:00:00") -> Data {
        box("udta", rawBox(tim, intlText(label)) + rawBox(tsc, intlText("24000")) + rawBox(tsz, intlText("1001")))
    }

    static let ftyp = box("ftyp", Data("mp42\0\0\0\0mp42isom".utf8))
    static let mdatPayload = Data(repeating: 0xAB, count: 4096)

    final class Recording: XMPByteSource {
        let inner: XMPDataSource
        var reads: [(UInt64, Int)] = []
        init(_ d: Data) { inner = XMPDataSource(d) }
        var byteCount: UInt64 { inner.byteCount }
        func bytes(at offset: UInt64, count: Int) -> Data? { reads.append((offset, count)); return inner.bytes(at: offset, count: count) }
    }

    func testUserDataIsReadFromMoovUdtaAndTheMediaIsNeverRead() {
        let moov = Self.box("moov", Self.box("mvhd", Data(count: 100))
                            + Self.box("trak", Self.box("udta", Self.rawBox(Self.tim, Self.intlText("09:00:00:00"))))
                            + Self.premiereUdta())
        let file = Self.ftyp + Self.box("mdat", Self.mdatPayload) + moov
        let src = Recording(file)
        let r = StartTimecodeMetadata.read(src)
        XCTAssertTrue(r.userDataPresent)
        XCTAssertEqual(r.userData?.label, "01:00:00:00", "moov/udta's, not the trak's")
        XCTAssertFalse(r.xmpPresent)
        XCTAssertNil(r.xmp)
        XCTAssertEqual(r.unreadable, 0)
        let mdatStart = UInt64(Self.ftyp.count + 8), mdatEnd = mdatStart + UInt64(Self.mdatPayload.count)
        for (o, n) in src.reads { XCTAssertFalse(o < mdatEnd && o + UInt64(n) > mdatStart, "read \(n) at \(o) inside mdat") }
        // Only a trak's udta: the movie has none.
        let trakOnly = Self.ftyp + Self.box("moov", Self.box("trak", Self.premiereUdta()))
        XCTAssertFalse(StartTimecodeMetadata.read(XMPDataSource(trakOnly)).userDataPresent)
    }

    func testBothSourcesFromOneFileAndUserDataWins() {
        let file = Self.ftyp + Self.box("moov", Self.premiereUdta())
            + Self.box("uuid", XMPBoxWalk.adobeXMPUUID + Self.packet(#"<xmpDM:startTimecode xmpDM:timeFormat="23976Timecode" xmpDM:timeValue="02:00:00:00"/>"#))
        let r = StartTimecodeMetadata.read(XMPDataSource(file))
        XCTAssertEqual(r.userData?.label, "01:00:00:00")
        XCTAssertEqual(r.xmp?.label, "02:00:00:00")
        let c = StartTimecodePrecedence.Candidates(userData: r.userData, xmp: r.xmp)
        XCTAssertEqual(StartTimecodePrecedence.file(c)?.source, .userData)
        XCTAssertEqual(StartTimecodePrecedence.file(.init(xmp: r.xmp))?.label, "02:00:00:00", "XMP alone")
    }

    func testAPresentButUnreadableUserDataIsCountedNotUsed() {
        let udta = Self.box("udta", Self.rawBox(Self.tim, Self.intlText("99:99:99:99")) + Self.rawBox(Self.tsc, Self.intlText("25")))
        let r = StartTimecodeMetadata.read(XMPDataSource(Self.ftyp + Self.box("moov", udta)))
        XCTAssertTrue(r.userDataPresent)
        XCTAssertNil(r.userData)
        XCTAssertEqual(r.unreadable, 1)
    }

    func testAFileThatIsNotABoxFileIsNotWalked() {
        // An MXF starts with a SMPTE universal label: never walked as boxes.
        let mxf = Data([0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01]) + Data(repeating: 0, count: 4096)
        let src = Recording(mxf)
        XCTAssertEqual(StartTimecodeMetadata.read(src), StartTimecodeMetadata.Result())
        XCTAssertEqual(src.reads.count, 1, "the first 8 bytes only")
        XCTAssertEqual(StartTimecodeMetadata.read(XMPDataSource(Data())), StartTimecodeMetadata.Result())
    }

    func testATruncatedFileKeepsWhatItReadAndNeverFails() {
        let file = Self.ftyp + Self.box("moov", Self.premiereUdta())
        for cut in stride(from: 1, to: file.count, by: 7) {
            _ = StartTimecodeMetadata.read(XMPDataSource(file.prefix(cut)))   // no crash, no trap
        }
    }

    // MARK: XMP

    static func packet(_ inner: String, pantry: String = "") -> Data {
        Data("""
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:xmpDM="http://ns.adobe.com/xmp/1.0/DynamicMedia/"
            xmlns:xmpMM="http://ns.adobe.com/xap/1.0/mm/" xmpDM:startTimeScale="24000" xmpDM:startTimeSampleSize="1001">
        \(inner)
        <xmpMM:Pantry><rdf:Bag><rdf:li><rdf:Description>\(pantry)</rdf:Description></rdf:li></rdf:Bag></xmpMM:Pantry>
        </rdf:Description></rdf:RDF></x:xmpmeta>
        <?xpacket end="w"?>
        """.utf8)
    }

    private func xmp(_ inner: String, pantry: String = "") -> (timecode: StartTimecode?, present: Bool) {
        StartTimecodeMetadata.xmp(Self.packet(inner, pantry: pantry))
    }

    func testXMPAsPremiereWritesIt() {
        let r = xmp("""
        <xmpDM:startTimecode
            xmpDM:timeFormat="23976Timecode"
            xmpDM:timeValue="01:00:00:00"/>
        <xmpDM:altTimecode
            xmpDM:timeValue="01:00:00:00"
            xmpDM:timeFormat="23976Timecode"/>
        """)
        XCTAssertTrue(r.present)
        XCTAssertEqual(r.timecode, StartTimecode(frameCount: 86_400, nfr: 24, fps: Self.r2398, dropFrame: false, source: .xmp))
    }

    func testXMPElementForm() {
        let r = xmp("""
        <xmpDM:startTimecode rdf:parseType="Resource">
            <xmpDM:timeFormat>25Timecode</xmpDM:timeFormat><xmpDM:timeValue>10:00:00:00</xmpDM:timeValue>
        </xmpDM:startTimecode>
        """)
        XCTAssertEqual(r.timecode?.frameCount, 900_000)
        XCTAssertEqual(r.timecode?.fps, 25)
    }

    func testXMPAltTimecodeWhenThereIsNoStartTimecode() {
        let r = xmp(#"<xmpDM:altTimecode xmpDM:timeFormat="24Timecode" xmpDM:timeValue="00:59:50:00"/>"#)
        XCTAssertEqual(r.timecode?.label, "00:59:50:00")
        // A readable startTimecode wins over altTimecode.
        let both = xmp(#"<xmpDM:altTimecode xmpDM:timeFormat="24Timecode" xmpDM:timeValue="00:59:50:00"/>"#
                       + #"<xmpDM:startTimecode xmpDM:timeFormat="24Timecode" xmpDM:timeValue="01:00:00:00"/>"#)
        XCTAssertEqual(both.timecode?.label, "01:00:00:00")
    }

    func testXMPDropFrame() {
        let df = xmp(#"<xmpDM:startTimecode xmpDM:timeFormat="2997DropTimecode" xmpDM:timeValue="01:00:00;00"/>"#)
        XCTAssertEqual(df.timecode?.frameCount, 107_892)
        XCTAssertEqual(df.timecode?.dropFrame, true)
        XCTAssertEqual(df.timecode?.label, "01:00:00;00")
        let colons = xmp(#"<xmpDM:startTimecode xmpDM:timeFormat="2997DropTimecode" xmpDM:timeValue="01:00:00:00"/>"#)
        XCTAssertEqual(colons.timecode?.frameCount, 107_892, "the format says drop-frame, whatever the punctuation")
        let df60 = xmp(#"<xmpDM:startTimecode xmpDM:timeFormat="5994DropTimecode" xmpDM:timeValue="01:00:00;00"/>"#)
        XCTAssertEqual(df60.timecode?.frameCount, 215_784)
        let ndf = xmp(#"<xmpDM:startTimecode xmpDM:timeFormat="2997NonDropTimecode" xmpDM:timeValue="01:00:00:00"/>"#)
        XCTAssertEqual(ndf.timecode?.frameCount, 108_000)
        XCTAssertEqual(ndf.timecode?.dropFrame, false)
    }

    func testXMPOddRates() {
        XCTAssertEqual(xmp(#"<xmpDM:startTimecode xmpDM:timeFormat="50Timecode" xmpDM:timeValue="00:00:01:49"/>"#).timecode?.frameCount, 99)
        XCTAssertEqual(xmp(#"<xmpDM:startTimecode xmpDM:timeFormat="11988Timecode" xmpDM:timeValue="00:00:00:119"/>"#).timecode?.nfr, 120)
        XCTAssertEqual(xmp(#"<xmpDM:startTimecode xmpDM:timeFormat="4795Timecode" xmpDM:timeValue="00:00:00:47"/>"#).timecode?.nfr, 48)
        XCTAssertNil(xmp(#"<xmpDM:startTimecode xmpDM:timeFormat="25Timecode" xmpDM:timeValue="00:00:00:25"/>"#).timecode)
    }

    func testTimeFormats() {
        func f(_ s: String) -> (Double, Bool)? { StartTimecodeMetadata.timeFormat(s).map { ($0.fps, $0.dropFrame) } }
        XCTAssertEqual(f("23976Timecode")?.0, Self.r2398)
        XCTAssertEqual(f("24Timecode")?.0, 24)
        XCTAssertEqual(f("25Timecode")?.0, 25)
        XCTAssertEqual(f("2997DropTimecode")?.0, Self.r2997)
        XCTAssertEqual(f("2997DropTimecode")?.1, true)
        XCTAssertEqual(f("2997NonDropTimecode")?.1, false)
        XCTAssertEqual(f("30Timecode")?.0, 30)
        XCTAssertEqual(f("50Timecode")?.0, 50)
        XCTAssertEqual(f("5994DropTimecode")?.0, Self.r5994)
        XCTAssertEqual(f("5994NonDropTimecode")?.1, false)
        XCTAssertEqual(f("60Timecode")?.0, 60)
        XCTAssertNil(f("25DropTimecode"), "no drop-frame at 25")
        XCTAssertNil(f("30DropTimecode"), "drop-frame is 29.97's, not 30's")
        XCTAssertNil(f("AudioSamplesTimecode"))
        XCTAssertNil(f("0Timecode"))
        XCTAssertNil(f("241Timecode"))
        XCTAssertNil(f("25"))
        XCTAssertNil(f(""))
    }

    func testXMPWithoutAReadableFormatUsesTheStartTimeScale() {
        let r = xmp(#"<xmpDM:startTimecode xmpDM:timeFormat="NotAFormat" xmpDM:timeValue="01:00:00:00"/>"#)
        XCTAssertEqual(r.timecode?.fps, Self.r2398, "startTimeScale 24000 / startTimeSampleSize 1001")
        XCTAssertEqual(r.timecode?.frameCount, 86_400)
    }

    func testAPantryStartTimecodeIsAnotherFilesAndNotRead() {
        let r = xmp("", pantry: #"<xmpDM:startTimecode xmpDM:timeFormat="25Timecode" xmpDM:timeValue="05:00:00:00"/>"#)
        XCTAssertFalse(r.present)
        XCTAssertNil(r.timecode)
    }

    func testAnUnreadableXMPTimecodeIsPresentButNotUsed() {
        let r = xmp(#"<xmpDM:startTimecode xmpDM:timeFormat="23976Timecode" xmpDM:timeValue="soon"/>"#)
        XCTAssertTrue(r.present)
        XCTAssertNil(r.timecode)
    }

    func testAnXMPPacketWithADTDIsRefused() {
        var p = Self.packet(#"<xmpDM:startTimecode xmpDM:timeFormat="25Timecode" xmpDM:timeValue="01:00:00:00"/>"#)
        p = Data("<!DOCTYPE x [<!ENTITY a \"b\">]>".utf8) + p
        XCTAssertFalse(StartTimecodeMetadata.xmp(p).present)
        XCTAssertFalse(StartTimecodeMetadata.xmp(Data("<x:xmpmeta".utf8)).present, "malformed")
    }

    // MARK: The basis every reader uses (§13.3)

    static let userData1h = StartTimecode(frameCount: 86_400, nfr: 24, fps: r2398, dropFrame: false, source: .userData)
    static let comment = Marker(frame: 186, duration: 96, name: "c", created: Date(timeIntervalSince1970: 0))

    func testAMetadataStartLabelsMarkersEntryAndEveryExport() throws {
        let b = TimecodeBasis.forFile(rate: Self.r2398, timecode: Self.userData1h, overrideLabel: nil)
        XCTAssertEqual(b.label(186), "01:00:07:18", "the ranged file's Comment")
        XCTAssertEqual(b.frame(label: "01:00:07:18"), 186)
        XCTAssertEqual(b.typedFrame("01:00:07:18", current: 0), 186, "typed entry lands on the same frame")
        XCTAssertTrue(b.hasTimecode)
        XCTAssertEqual(b.source, .userData)
        XCTAssertEqual(b.fileSource, .userData)
        XCTAssertTrue(b.overrideAvailable)
        XCTAssertEqual(b.fileLabel, "01:00:00:00")
        XCTAssertEqual(b.fileOwn, b)

        let edl = ResolveEDL.export(markers: [Self.comment], title: "t", basis: b).text
        XCTAssertTrue(edl.contains("01:00:07:18 01:00:07:19"), edl)
        let csv = String(decoding: MarkerCSV.export(markers: [Self.comment], basis: b), as: UTF8.self)
        XCTAssertTrue(csv.contains("01:00:07:18"), csv)
        let text = MarkerPlainText.export(markers: [Self.comment], fileName: "f.mp4", basis: b)
        XCTAssertTrue(text.contains("Start timecode: 01:00:00:00 (from the file's metadata)\n"), text)
        XCTAssertEqual(PremiereXML.timecodeString(b.fileOwn), PremiereXML.timecodeString(b))

        // The EDL places straight back, with no whole-hour shift offered.
        let placed = ResolveEDL.place(try ResolveEDL.parse(Data(edl.utf8)), basis: b, lastFrame: 719)
        XCTAssertEqual(placed.markers.map(\.frame), [186])
        XCTAssertNil(placed.suggestedShiftHours)
        XCTAssertEqual(placed.outside, [])
    }

    func testTheOverrideOverAMetadataStartDrivesEveryLabelAndTheClipKeepsItsOwn() {
        let b = TimecodeBasis.forFile(rate: Self.r2398, timecode: Self.userData1h, overrideLabel: "02:00:00:00")
        XCTAssertEqual(b.label(186), "02:00:07:18")
        XCTAssertEqual(b.source, .override)
        XCTAssertFalse(b.hasTimecode)
        XCTAssertTrue(b.overrideAvailable, "still offered, to change or reset")
        XCTAssertEqual(b.fileLabel, "01:00:00:00")
        XCTAssertEqual(b.fileOwn.label(186), "01:00:07:18", "Premiere XML's clip timecode is the file's own")
        XCTAssertTrue(ResolveEDL.export(markers: [Self.comment], title: "t", basis: b).text.contains("02:00:07:18"))
        XCTAssertTrue(MarkerPlainText.export(markers: [], fileName: "f", basis: b)
            .contains("Start timecode: 02:00:00:00 (set in Manifold, replacing the file's metadata timecode)\n"))
        // The engine's effective timecode is the same function's answer.
        XCTAssertEqual(StartTimecodePrecedence.effective(file: Self.userData1h, overrideLabel: "02:00:00:00", rate: Self.r2398)?.frameCount,
                       b.startFrame)
    }

    func testATmcdOrContainerStartIsNeverReplaced() {
        for source in [StartTimecodeSource.tmcd, .container] {
            let own = StartTimecode(frameCount: 864_000, nfr: 24, fps: Self.r2398, dropFrame: false, source: source)
            let b = TimecodeBasis.forFile(rate: Self.r2398, timecode: own, overrideLabel: "01:00:00:00")
            XCTAssertEqual(b.label(0), "10:00:00:00", "\(source)")
            XCTAssertEqual(b.source, source)
            XCTAssertFalse(b.overrideAvailable, "\(source)")
            XCTAssertTrue(MarkerPlainText.export(markers: [], fileName: "f", basis: b).contains("Start timecode: 10:00:00:00\n"))
        }
    }

    func testAFileWithoutTimecodeIsAsBefore() {
        let b = TimecodeBasis.forFile(rate: 25, timecode: nil, overrideLabel: "01:00:00:00")
        XCTAssertEqual(b.startFrame, 90_000)
        XCTAssertFalse(b.hasTimecode)
        XCTAssertEqual(b.source, .override)
        XCTAssertNil(b.fileSource)
        XCTAssertNil(b.fileLabel)
        XCTAssertTrue(b.overrideAvailable)
        XCTAssertEqual(b.fileOwn.startFrame, 0)
        XCTAssertEqual(b, TimecodeBasis.forFile(rate: 25, timecodeStartFrame: nil, timecodeNFR: nil, dropFrame: false,
                                                overrideLabel: "01:00:00:00"), "the pre-Stage 4 form agrees")
        XCTAssertTrue(MarkerPlainText.export(markers: [], fileName: "f", basis: b).contains("(the file has no timecode)"))
        let none = TimecodeBasis.forFile(rate: 25, timecode: nil, overrideLabel: nil)
        XCTAssertEqual(none.startFrame, 0)
        XCTAssertNil(none.source)
    }

    func testThePreStage4FormWithATrackIsATmcdStart() {
        let b = TimecodeBasis.forFile(rate: Self.r2997, timecodeStartFrame: 107_892, timecodeNFR: 30, dropFrame: true,
                                      overrideLabel: "05:00:00;00")
        XCTAssertEqual(b.label(0), "01:00:00;00")
        XCTAssertEqual(b.source, .tmcd)
        XCTAssertFalse(b.overrideAvailable)
    }

    // MARK: Log

    func testTheLogLineHoldsTheSourceKindAndCountsOnly() {
        var m = StartTimecodeMetadata.Result()
        m.userDataPresent = true
        m.userData = Self.userData1h
        m.xmpPresent = true
        let line = StartTimecodeLog.line(source: .userData, metadata: m)
        XCTAssertEqual(line, "[TIMECODE] start source=user-data user-data=1 xmp=1 unreadable=1")
        XCTAssertFalse(line.contains("01:00"))
        XCTAssertEqual(StartTimecodeLog.line(source: nil, metadata: .init()), "[TIMECODE] start source=none user-data=0 xmp=0 unreadable=0")
    }
}

/// The "start timecode now reads differently" notice across Stage 4 (§13.3: Premiere MP4s with stored markers).
final class StartTimecodeNoticeTests: XCTestCase {
    static let r2398 = 24000.0 / 1001
    static func basis(_ label: String?, _ source: StartTimecodeSource = .userData, override: String? = nil) -> TimecodeBasis {
        TimecodeBasis.forFile(rate: r2398, timecode: label.flatMap { StartTimecode(label: $0, fps: r2398, source: source) },
                              overrideLabel: override)
    }

    func testAPremiereMP4WithStoredMarkersIsToldOnceAndWhy() {
        let c = StartTimecodeNotice.check(seen: nil, basis: Self.basis("01:00:00:00"), storedOverride: nil, hasMarkers: true)
        XCTAssertEqual(c.notice, "This file’s start timecode is now read from the file’s metadata: 01:00:00:00. Its markers were made when it read 00:00:00:00. They stay on the same frames.")
        XCTAssertTrue(c.saveSeen, "saved as seen, so the next open is quiet")
        let next = StartTimecodeNotice.check(seen: "01:00:00:00", basis: Self.basis("01:00:00:00"), storedOverride: nil, hasMarkers: true)
        XCTAssertNil(next.notice)
        XCTAssertEqual(StartTimecodeNotice.check(seen: nil, basis: Self.basis("01:00:00:00", .xmp), storedOverride: nil,
                                                 hasMarkers: true).saveSeen, true)
    }

    func testAMetadataStartAt00IsSavedUntold() {
        let c = StartTimecodeNotice.check(seen: nil, basis: Self.basis("00:00:00:00"), storedOverride: nil, hasMarkers: true)
        XCTAssertNil(c.notice)
        XCTAssertTrue(c.saveSeen)
    }

    func testAStoredOverrideStillAppliesSoNothingMoved() {
        let b = Self.basis("01:00:00:00", override: "02:00:00:00")
        XCTAssertEqual(StartTimecodeNotice.check(seen: nil, basis: b, storedOverride: "02:00:00:00", hasMarkers: true).notice, nil)
        XCTAssertNil(StartTimecodeNotice.check(seen: "00:59:00:00", basis: b, storedOverride: "02:00:00:00", hasMarkers: true).notice)
    }

    func testATmcdFileIsAsBefore() {
        let b = Self.basis("10:00:00:00", .tmcd)
        XCTAssertNil(StartTimecodeNotice.check(seen: nil, basis: b, storedOverride: nil, hasMarkers: true).notice,
                     "no seen and a track: never told (a document saved before seen existed)")
        XCTAssertEqual(StartTimecodeNotice.check(seen: "01:00:00:00", basis: b, storedOverride: nil, hasMarkers: true).notice,
                       "This file’s start timecode now reads 10:00:00:00; its markers were made at 01:00:00:00. They stay on the same frames.")
    }

    func testNoMarkersOrNoTimecodeNothing() {
        XCTAssertEqual(StartTimecodeNotice.check(seen: nil, basis: Self.basis("01:00:00:00"), storedOverride: nil, hasMarkers: false).saveSeen, false)
        XCTAssertNil(StartTimecodeNotice.check(seen: "01:00:00:00", basis: Self.basis(nil), storedOverride: nil, hasMarkers: true).notice)
    }
}
