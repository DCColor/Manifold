//
//  LiveDecodeFailureTests.swift
//  ColorimetryModelTests
//
//  Which VideoToolbox decode failures refuse a live stream at once (§6.10, S3/S4 follow-up).
//

import XCTest
@testable import ColorimetryModel

final class LiveDecodeFailureTests: XCTestCase {

    /// "No decoder for this format" refuses now.
    func testUnsupportedFormatCodesRefuseAtOnce() {
        for status: Int32 in [-12906, -12910, -8970] {
            XCTAssertEqual(LiveDecodeFailure(status: status), .unsupportedFormat, "\(status)")
        }
    }

    /// Damage waits for the next random-access picture — including −8969, the code VideoToolbox gives
    /// H.264 4:2:2 in software (measured), which is why the backstop exists.
    func testDataErrorsWait() {
        for status: Int32 in [-12909, -8969, -12911, -12913, -12916, -1] {
            XCTAssertEqual(LiveDecodeFailure(status: status), .data, "\(status)")
        }
        XCTAssertGreaterThan(LiveDecodeFailure.dataFailuresBeforeRefusal, 1,
                             "one damaged keyframe must never refuse a stream")
    }
}
