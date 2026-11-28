import XCTest
@testable import DeckLinkRefusal

/// Inactive DeckLink sub-devices (Robbie, 2026-11-15): BMDDeckLinkDuplex read, and what a mapping change does to output.
final class DeckLinkConnectorMappingTests: XCTestCase {
    /// The codes are the SDK 16.0 header's (DeckLinkAPI.h, BMDDuplexMode), as four-character codes.
    func testCodesAreTheHeadersFourCharacterCodes() {
        func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
        XCTAssertEqual(DeckLinkDuplex.fullCode, fourCC("dxfu"))
        XCTAssertEqual(DeckLinkDuplex.halfCode, fourCC("dxha"))
        XCTAssertEqual(DeckLinkDuplex.simplexCode, fourCC("dxsp"))
        XCTAssertEqual(DeckLinkDuplex.inactiveCode, fourCC("dxin"))
    }

    func testOnlyTheInactiveCodeGreysADeviceOut() {
        XCTAssertEqual(DeckLinkDuplex(code: 0x6478_696E), .inactive)
        XCTAssertTrue(DeckLinkDuplex(code: 0x6478_696E).isInactive)
        for code: UInt32? in [DeckLinkDuplex.fullCode, DeckLinkDuplex.halfCode, DeckLinkDuplex.simplexCode, 0, 0x1234, nil] {
            XCTAssertFalse(DeckLinkDuplex(code: code).isInactive, "\(String(describing: code))")
        }
        XCTAssertEqual(DeckLinkDuplex(code: nil), .unknown)
        XCTAssertEqual(DeckLinkDuplex(code: 7), .unknown)
    }

    /// Robbie's mapping "SDI 1 & 2 In, SDI 3 & 4 Out", one sub-device: (1) active, (2)–(4) inactive.
    func testOneSubDeviceMappingGreysTwoToFour() {
        let read: [UInt32?] = [DeckLinkDuplex.fullCode, DeckLinkDuplex.inactiveCode, DeckLinkDuplex.inactiveCode,
                               DeckLinkDuplex.inactiveCode]
        XCTAssertEqual(read.map { DeckLinkDuplex(code: $0).isInactive }, [false, true, true, true])
    }

    func testNothingHappensWhileOutputIsOff() {
        XCTAssertNil(DeckLinkConnectorMapping.verdictAfterChange(outputting: false, selected: .inactive,
                                                                 deviceName: "DeckLink 8K Pro (2)", forcedStop: true))
    }

    func testSelectedDeviceBecomingInactiveStopsOutputAndNamesIt() {
        let m = DeckLinkConnectorMapping.verdictAfterChange(outputting: true, selected: .inactive,
                                                            deviceName: "DeckLink 8K Pro (2)", forcedStop: false)
        XCTAssertEqual(m, DeckLinkConnectorMapping.becameInactiveMessage(device: "DeckLink 8K Pro (2)"))
        XCTAssertTrue(m?.contains("DeckLink 8K Pro (2) stopped being active") ?? false)
        XCTAssertTrue(m?.contains("start output again") ?? false)
    }

    func testSelectedDeviceGoneStopsOutput() {
        XCTAssertNotNil(DeckLinkConnectorMapping.verdictAfterChange(outputting: true, selected: nil,
                                                                    deviceName: "DeckLink 8K Pro (1)", forcedStop: false))
    }

    /// The driver stopped the stream for the change, the device still active: say so, never restart on our own.
    func testForcedStopOnAStillActiveDeviceSaysTheMappingChanged() {
        XCTAssertEqual(DeckLinkConnectorMapping.verdictAfterChange(outputting: true, selected: .full,
                                                                   deviceName: "x", forcedStop: true),
                       DeckLinkConnectorMapping.mappingChangedMessage)
    }

    /// A change that leaves the selected device active and its stream running changes nothing.
    func testUnforcedChangeOnAnActiveDeviceLeavesOutputRunning() {
        for d in [DeckLinkDuplex.full, .half, .simplex, .unknown] {
            XCTAssertNil(DeckLinkConnectorMapping.verdictAfterChange(outputting: true, selected: d, deviceName: "x",
                                                                     forcedStop: false), d.logName)
        }
    }
}
