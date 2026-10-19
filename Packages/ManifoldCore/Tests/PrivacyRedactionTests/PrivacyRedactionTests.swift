import XCTest
@testable import PrivacyRedaction

/// Privacy stage P1 (docs/PRIVACY_AUDIT.md). Every line in these corpora is the SHAPE of a real
/// Manifold log line — the ICE pair from DataChannelBridge, the NDI discovery listing, the SRT
/// stream-id line, the [REFERENCE] calibration line — with invented values.
final class LogRedactionTests: XCTestCase {

    // MARK: IP addresses

    func testICEPairLosesBothAddresses() {
        let pair = "a=candidate:1 1 UDP 2122317823 192.168.1.23 54012 typ host  ->  "
                 + "a=candidate:2 1 UDP 1686052607 104.18.2.3 3478 typ srflx raddr 0.0.0.0 rport 0"
        let out = LogRedaction.withholdingIPAddresses(pair)
        XCTAssertFalse(out.contains("192.168"))
        XCTAssertFalse(out.contains("104.18"))
        XCTAssertFalse(out.contains("0.0.0.0"))
        // What the line is FOR survives: candidate types, transport and ports.
        XCTAssertTrue(out.contains("typ host"))
        XCTAssertTrue(out.contains("typ srflx"))
        XCTAssertTrue(out.contains("54012"))
        XCTAssertEqual(out.components(separatedBy: LogRedaction.ipWithheld).count - 1, 3)
    }

    func testIPv4WithPortAndAtSentenceEnd() {
        XCTAssertEqual(LogRedaction.withholdingIPAddresses("source at 10.0.0.2:5961"),
                       "source at (ip withheld)")
        XCTAssertEqual(LogRedaction.withholdingIPAddresses("connected to 10.0.0.2."),
                       "connected to (ip withheld).")
    }

    func testIPv6Forms() {
        let cases = [
            "fe80::1c2b:3aff:fe11:2233%en0",
            "2a02:8010:6400:1:a8b2:c3d4:e5f6:7788",
            "::1",
            "2001:db8::7",
            "::ffff:192.0.2.1",
        ]
        for c in cases {
            XCTAssertEqual(LogRedaction.withholdingIPAddresses("host \(c) typ host"),
                           "host (ip withheld) typ host", c)
        }
        XCTAssertEqual(LogRedaction.withholdingIPAddresses("[2001:db8::7]:5000"), "[(ip withheld)]:5000")
    }

    func testThingsThatAreNotAddressesSurvive() {
        let lines = [
            "[WEBRTC] (4) rtc::impl::PeerConnection::changeState: Changed state to connected",
            "std::string and std::vector",
            "timecode 01:00:00:00 at 12:30:44.123",
            "libsrt 1.5.6 | libavformat 62.3.100",
            "chroma 4:2:2 → x422",
            "Manifold 0.8.4 (build 19)",
            "date 2026-10-19 20:57:14",
            "#!::m=publish",
        ]
        for l in lines { XCTAssertEqual(LogRedaction.withholdingIPAddresses(l), l, l) }
    }

    // MARK: SRT stream ids

    func testPlainStreamIdIsWithheldWhole() {
        // The bypass this stage closes: a freeform id used to come back unchanged.
        XCTAssertEqual(LogRedaction.srtStreamId("live_8f3a9c2e1b"), "(withheld)")
        XCTAssertEqual(LogRedaction.srtStreamId("publish:live/abc"), "(withheld)")
        XCTAssertEqual(LogRedaction.srtStreamId(""), "(none)")
    }

    func testAccessControlStreamIdKeepsKeysAndEnums() {
        XCTAssertEqual(LogRedaction.srtStreamId("#!::r=live/key123,m=publish,s=tok,u=bob,t=stream"),
                       "#!::r=(withheld),m=publish,s=(withheld),u=(withheld),t=stream")
        // A value containing "=" stays withheld whole.
        XCTAssertEqual(LogRedaction.srtStreamId("#!::s=a=b"), "#!::s=(withheld)")
    }

    // MARK: NDI

    func testNDINameLosesItsHost() {
        XCTAssertEqual(LogRedaction.ndiSourceName("MAC-STUDIO (E8 Bars)"), "(host withheld) (E8 Bars)")
        XCTAssertEqual(LogRedaction.ndiSourceName("192.168.1.5 (OBS)"), "(host withheld) (OBS)")
        // The host is everything before the FIRST " (": a stream name may itself contain brackets.
        XCTAssertEqual(LogRedaction.ndiSourceName("STUDIO-PC (Cam (wide))"), "(host withheld) (Cam (wide))")
        XCTAssertEqual(LogRedaction.ndiSourceName("Bars"), "Bars")
        XCTAssertEqual(LogRedaction.ndiSourceName("feed 10.1.1.1"), "feed (ip withheld)")
    }
}

final class DiagnosticsRedactionTests: XCTestCase {

    private func redact(_ s: String, _ o: DiagnosticsRedaction.Options = .init()) -> String {
        DiagnosticsRedaction.redact(s, options: o).text
    }

    func testExistingCredentialRulesStillFire() {
        let out = redact("""
            srt://ingest.example.com:9000?streamid=#!::r=live,s=tok&passphrase=hunter2hunter2
            Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.e30.x
            https://customer-abc.cloudflarestream.com/key0123456789/webRTC/play
            """)
        XCTAssertFalse(out.contains("hunter2"))
        XCTAssertFalse(out.contains("eyJ"))
        XCTAssertFalse(out.contains("key0123456789"))
        XCTAssertFalse(out.contains("s=tok"))
        XCTAssertTrue(out.contains("customer-abc.cloudflarestream.com/(path withheld)"))
    }

    func testIPHostsInURLsAndLogLines() {
        let out = redact("""
            [WHEP] POST http://127.0.0.1:8889/live/whep
            [NDI]   [0] MAC-STUDIO (E8 Bars)  (192.168.1.40:5961)
            candidate fe80::1c2b:3aff:fe11:2233%en0 61234
            """)
        XCTAssertFalse(out.contains("127.0.0.1"))
        XCTAssertFalse(out.contains("192.168"))
        XCTAssertFalse(out.contains("fe80"))
        XCTAssertTrue(out.contains("http://(ip withheld)/(path withheld)"))
    }

    func testPreservedVersionIsNotTakenForAnAddress() {
        let line = "[NDI] runtime version: NDI SDK APPLE 13:30:12 Sep  4 2025 6.3.2.0"
        XCTAssertEqual(redact(line, .init(preserve: ["NDI SDK APPLE 13:30:12 Sep  4 2025 6.3.2.0"])), line)
        // Without the preserve entry the version IS IPv4-shaped and goes — over-redaction, by design.
        XCTAssertFalse(redact(line).contains("6.3.2.0"))
    }

    func testAbsolutePathsAreWithheldOutsideSystemRoots() {
        let out = redact("""
            [EXPORT] wrote /Users/robbie/Desktop/Manifold_frame_1760900000.png
            [STEP] opened /Volumes/Media/Shoot Day 2/A001_C003.mov ok
            [WAV] ~/Desktop/Manifold-NDI-x.wav
            [NDI] runtime loaded: /usr/local/lib/libndi.dylib
            [DeckLink] /Library/Frameworks/DeckLinkAPI.framework
            tmp /private/var/folders/sp/t_svp/T/x.dat
            file:///Volumes/Media/A001.mov
            """)
        XCTAssertFalse(out.contains("robbie"))
        XCTAssertFalse(out.contains("/Volumes"))
        XCTAssertFalse(out.contains("Shoot Day"))
        XCTAssertFalse(out.contains("A001"))
        XCTAssertFalse(out.contains("Desktop"))
        XCTAssertFalse(out.contains("/private"))
        XCTAssertFalse(out.contains("Manifold_frame"))
        XCTAssertTrue(out.contains("/usr/local/lib/libndi.dylib"))
        XCTAssertTrue(out.contains("/Library/Frameworks/DeckLinkAPI.framework"))
        XCTAssertTrue(out.contains("[STEP] opened (path withheld) ok"))
    }

    func testKnownPathWithSpacesIsRemovedExactly() {
        let path = "/Volumes/DCCOLOR/TEST FLIP/MXF NCLc Matrix/cs709 g24 v2.mxf"
        let log = """
            [FILE] loading \(path) (MXF)
            [STEP] cs709 g24 v2.mxf → frame 12
            """
        let off = redact(log, .init(knownPaths: [path]))
        XCTAssertFalse(off.contains("DCCOLOR"))
        XCTAssertFalse(off.contains("cs709"))
        XCTAssertTrue(off.contains("[FILE] loading (path withheld) (MXF)"))
        XCTAssertTrue(off.contains("[STEP] (file name withheld) → frame 12"))

        let on = redact(log, .init(includeFileNames: true, knownPaths: [path]))
        XCTAssertFalse(on.contains("DCCOLOR"))
        XCTAssertFalse(on.contains("TEST FLIP"))
        XCTAssertTrue(on.contains("(path withheld)/cs709 g24 v2.mxf"))
        XCTAssertTrue(on.contains("[STEP] cs709 g24 v2.mxf → frame 12"))
    }

    func testAKnownFolderDoesNotWithholdItsNameAsAWord() {
        // The export folder is a known path; its name must not become a withheld "file name".
        let log = "DeckLink: Desktop Video 16.4.0 — 4 enumerated\n[EXPORT] wrote /Users/x/Desktop/Manifold_frame_1.png"
        let out = redact(log, .init(knownPaths: ["/Users/x/Desktop"]))
        XCTAssertTrue(out.contains("DeckLink: Desktop Video 16.4.0"))
        XCTAssertFalse(out.contains("/Users/x"))
        XCTAssertFalse(out.contains("Manifold_frame_1"))
    }

    func testBareFileNamesByExtension() {
        let log = "[CONTAINER] clip_v2.MXF: AVFoundation exposes no video track; LUT Show-LUT.cube"
        let off = redact(log)
        XCTAssertFalse(off.contains("clip_v2"))
        XCTAssertFalse(off.contains("Show-LUT"))
        XCTAssertEqual(redact(log, .init(includeFileNames: true)), log)
        // Not file names: dylibs, versions, the app's own name.
        let keep = "libavcodec.62.dylib Manifold 0.8.4 h264 SRT stream"
        XCTAssertEqual(redact(keep), keep)
    }

    func testDisplaySerials() {
        let log = "[REFERENCE] display \"LG HDR 4K\" (7789-30566-16843009): Rec.709"
        let out = redact(log, .init(displaySerials: ["16843009", "0", "12"]))
        XCTAssertFalse(out.contains("16843009"))
        XCTAssertTrue(out.contains("7789-30566-(serial withheld)"))
        // Short serials are ignored rather than shredding every small number in the log.
        XCTAssertEqual(redact("frame 12 of 120", .init(displaySerials: ["12"])), "frame 12 of 120")
        XCTAssertFalse(redact("Serial Number: C02XK1ABJGH5").contains("C02XK1"))
    }

    func testMachineNamesAreWithheld() {
        let log = """
            [NDI] connected to "MAC-STUDIO (E8 Bars)"
            Mac-Studio.local resolved; studio-mac-mini kept
            """
        let out = redact(log, .init(hostNames: ["MAC-STUDIO", "Mac-Studio.local"]))
        XCTAssertFalse(out.contains("MAC-STUDIO"))
        XCTAssertFalse(out.contains("Mac-Studio.local"))
        XCTAssertTrue(out.contains("(host withheld) (E8 Bars)"))
        XCTAssertTrue(out.contains("studio-mac-mini kept"), "a different name containing it is not touched")
    }

    func testEveryRuleCompilesAndIsReported() {
        let hits = DiagnosticsRedaction.redact("nothing here").hits
        XCTAssertFalse(hits.contains { $0.count < 0 }, "\(hits)")
        XCTAssertTrue(hits.contains { $0.label == "IP addresses" })
    }
}
