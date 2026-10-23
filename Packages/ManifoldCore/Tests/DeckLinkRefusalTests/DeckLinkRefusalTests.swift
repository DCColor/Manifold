import XCTest
@testable import DeckLinkRefusal

/// Only the measured busy answer from EnableVideoOutput gets the message (docs/BUGS.md, the 2160p23.98 refusal).
final class DeckLinkRefusalTests: XCTestCase {
    private func hr(_ v: UInt32) -> Int32 { Int32(bitPattern: v) }

    func testBusyEnableGetsTheMessage() {
        XCTAssertEqual(DeckLinkRefusal.message(call: "EnableVideoOutput", hresult: hr(0x8000_0009)),
                       DeckLinkRefusal.busyMessage)
    }

    func testMessageNamesResolveAndSaysToRestart() {
        XCTAssertTrue(DeckLinkRefusal.busyMessage.hasPrefix(
            "DeckLink output is in use by another application (for example DaVinci Resolve)"))
        XCTAssertTrue(DeckLinkRefusal.busyMessage.contains("Start output again"))
    }

    /// E_FAIL, E_INVALIDARG, E_OUTOFMEMORY and S_OK from the same call keep their log line only.
    func testOtherEnableCodesHaveNoMessage() {
        for code: UInt32 in [0x8000_0008, 0x8000_0003, 0x8000_0002, 0x0000_0000, 0x8007_0005] {
            XCTAssertNil(DeckLinkRefusal.message(call: "EnableVideoOutput", hresult: hr(code)), String(format: "0x%08X", code))
        }
    }

    /// The busy code from any other call is not mapped: it has not been measured there.
    func testBusyCodeFromOtherCallsHasNoMessage() {
        for call in ["EnableAudioOutput", "DoesSupportVideoMode", "StartScheduledPlayback", "CreateVideoFrame",
                     "ScheduleVideoFrame", "QueryInterface(IDeckLinkOutput)"] {
            XCTAssertNil(DeckLinkRefusal.message(call: call, hresult: hr(0x8000_0009)), call)
        }
        XCTAssertNil(DeckLinkRefusal.message(call: nil, hresult: hr(0x8000_0009)))
    }
}
