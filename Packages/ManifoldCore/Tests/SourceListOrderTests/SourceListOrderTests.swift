import XCTest
@testable import SourceListOrder

final class SourceListOrderTests: XCTestCase {
    private struct Source: Equatable { let name: String; let url: String? }
    private func s(_ name: String, _ url: String? = nil) -> Source { Source(name: name, url: url) }
    private func merge(_ shown: [Source], _ polled: [Source]) -> [Source] {
        SourceListOrder.merged(shown: shown, polled: polled, id: \.name)
    }
    private func changed(_ a: [Source], _ b: [Source]) -> Bool {
        SourceListOrder.changed(a, b) { [$0.name, $0.url ?? ""] }
    }

    /// The measured case: the same sources every second publish nothing.
    func testSamePollIsUnchanged() {
        let shown = [s("A"), s("B")]
        let next = merge(shown, [s("A"), s("B")])
        XCTAssertEqual(next, shown)
        XCTAssertFalse(changed(shown, next))
    }

    /// The SDK may list the sources in another order; the rows do not move.
    func testReorderedPollKeepsShownOrder() {
        let shown = [s("B"), s("A")]
        let next = merge(shown, [s("A"), s("B")])
        XCTAssertEqual(next.map(\.name), ["B", "A"])
        XCTAssertFalse(changed(shown, next))
    }

    /// A source that sorts first in the SDK's list still goes to the end: the row under the pointer stays put.
    func testArrivalIsAppended() {
        let shown = [s("M"), s("Z")]
        let next = merge(shown, [s("A"), s("M"), s("Z")])
        XCTAssertEqual(next.map(\.name), ["M", "Z", "A"])
        XCTAssertTrue(changed(shown, next))
    }

    /// Several arrivals in one poll keep the SDK's order among themselves.
    func testArrivalsKeepPolledOrder() {
        XCTAssertEqual(merge([s("M")], [s("C"), s("M"), s("B")]).map(\.name), ["M", "C", "B"])
    }

    /// A source that leaves is dropped; the rest keep their relative order.
    func testDepartureIsDropped() {
        let shown = [s("A"), s("B"), s("C")]
        let next = merge(shown, [s("C"), s("A")])
        XCTAssertEqual(next.map(\.name), ["A", "C"])
        XCTAssertTrue(changed(shown, next))
    }

    /// The first poll fills an empty list in the SDK's order; an empty poll empties it.
    func testFromAndToEmpty() {
        XCTAssertEqual(merge([], [s("B"), s("A")]).map(\.name), ["B", "A"])
        XCTAssertEqual(merge([s("A")], []), [])
        XCTAssertFalse(changed([], merge([], [])))
    }

    /// A source keeps its place when only its address changes, and the change is published with the new address.
    func testAddressChangeIsPublishedInPlace() {
        let shown = [s("A", "10.0.0.1:5961"), s("B", "10.0.0.2:5961")]
        let next = merge(shown, [s("B", "10.0.0.2:5961"), s("A", "10.0.0.9:5961")])
        XCTAssertEqual(next, [s("A", "10.0.0.9:5961"), s("B", "10.0.0.2:5961")])
        XCTAssertTrue(changed(shown, next))
    }

    /// A name the SDK lists twice appears once (the menu's rows are identified by name).
    func testRepeatedNameAppearsOnce() {
        XCTAssertEqual(merge([], [s("A", "1"), s("A", "2"), s("B")]), [s("A", "1"), s("B")])
    }
}
