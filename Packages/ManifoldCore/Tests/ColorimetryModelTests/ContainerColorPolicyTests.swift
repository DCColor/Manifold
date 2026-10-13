//
//  ContainerColorPolicyTests.swift
//  ColorimetryModelTests
//
//  The container drives the picture (decided 2026-10-12, COLOR_MANAGEMENT_FINDINGS.md §6.11): per axis, the
//  container's statement where it makes one, else the decoder's; a disagreement is reported, never acted on.
//

import XCTest
@testable import ColorimetryModel

final class ContainerColorPolicyTests: XCTestCase {

    /// The measured case: a DNxHR MXF whose descriptor says BT.470BG (5) while ffmpeg's decoder says bt709 (1).
    func testContainerMatrixWinsOverTheDNxDecoder() {
        XCTAssertEqual(ContainerColorPolicy.resolve(container: 5, decoder: 1, .matrix), 5)
        XCTAssertEqual(ContainerColorPolicy.resolve(container: 9, decoder: 1, .matrix), 9)
    }

    /// An axis the container does not state follows the decoder, exactly as before the change.
    func testUnstatedContainerAxisFollowsTheDecoder() {
        for unstated in [2, 3] {
            XCTAssertEqual(ContainerColorPolicy.resolve(container: unstated, decoder: 1, .matrix), 1)
            XCTAssertEqual(ContainerColorPolicy.resolve(container: unstated, decoder: 6, .primaries), 6)
            XCTAssertEqual(ContainerColorPolicy.resolve(container: unstated, decoder: 16, .transfer), 16)
        }
        // 0 is reserved for primaries and transfer, and a statement (identity / GBR) for the matrix.
        XCTAssertEqual(ContainerColorPolicy.resolve(container: 0, decoder: 1, .primaries), 1)
        XCTAssertEqual(ContainerColorPolicy.resolve(container: 0, decoder: 1, .transfer), 1)
        XCTAssertEqual(ContainerColorPolicy.resolve(container: 0, decoder: 1, .matrix), 0)
    }

    func testDisagreements() {
        // The DNx MXF: matrix only; primaries and transfer agree.
        XCTAssertEqual(ContainerColorPolicy.disagreements(container: (6, 1, 5), decoder: (6, 1, 1)),
                       [ColorAxisDisagreement(axis: .matrix, container: 5, decoder: 1)])
        // One value spelled two ways is not a disagreement: matrix 5 / 6, transfer 1 / 6 / 14 / 15.
        XCTAssertEqual(ContainerColorPolicy.disagreements(container: (9, 14, 5), decoder: (9, 1, 6)), [])
        // A side that states nothing is not a disagreement.
        XCTAssertEqual(ContainerColorPolicy.disagreements(container: (2, 2, 2), decoder: (1, 1, 1)), [])
        XCTAssertEqual(ContainerColorPolicy.disagreements(container: (9, 16, 9), decoder: (2, 2, 2)), [])
        // A real one on every axis.
        XCTAssertEqual(ContainerColorPolicy.disagreements(container: (9, 16, 9), decoder: (1, 1, 1)).map(\.axis),
                       [.primaries, .transfer, .matrix])
    }

    func testReadout() {
        XCTAssertNil(ContainerColorPolicy.readout([], decoder: "dnxhd"))
        let line = ContainerColorPolicy.readout([ColorAxisDisagreement(axis: .matrix, container: 5, decoder: 1)],
                                                decoder: "dnxhd")
        XCTAssertEqual(line, "⚠️ container disagrees with the dnxhd decoder: matrix 5 vs 1"
                           + " — the container's tags are used; the override can assert the other")
    }
}
