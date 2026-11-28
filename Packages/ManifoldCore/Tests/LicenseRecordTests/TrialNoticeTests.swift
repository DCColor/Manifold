//
//  TrialNoticeTests.swift
//  LicenseRecordTests — the launch notice near the end of the trial (docs/BUGS.md, 0.9.6 UI polish item 34).
//

import XCTest
@testable import LicenseRecord

final class TrialNoticeTests: XCTestCase {

    func testThreeDaysOrFewer() {
        XCTAssertEqual(TrialNotice.text(daysRemaining: 3), "3 days left in your trial.")
        XCTAssertEqual(TrialNotice.text(daysRemaining: 2), "2 days left in your trial.")
        XCTAssertEqual(TrialNotice.text(daysRemaining: 1), "1 day left in your trial.")
    }

    /// More than three days: Settings ▸ License only. None left: the trial-ended screen, not a notice.
    func testOutsideTheWindowIsSilent() {
        XCTAssertNil(TrialNotice.text(daysRemaining: 7))
        XCTAssertNil(TrialNotice.text(daysRemaining: 4))
        XCTAssertNil(TrialNotice.text(daysRemaining: 0))
        XCTAssertNil(TrialNotice.text(daysRemaining: -1))
    }
}
