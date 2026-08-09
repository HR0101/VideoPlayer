import XCTest
import MediaServerKit

final class RangeHeaderTests: XCTestCase {

    func testFullRangeFromStart() {
        let r = RangeHeader.parse("bytes=0-", totalSize: 1000)
        XCTAssertEqual(r?.0, 0)
        XCTAssertEqual(r?.1, 999)
    }

    func testExplicitRange() {
        let r = RangeHeader.parse("bytes=100-199", totalSize: 1000)
        XCTAssertEqual(r?.0, 100)
        XCTAssertEqual(r?.1, 199)
    }

    func testEndClampedToTotalSize() {
        let r = RangeHeader.parse("bytes=900-5000", totalSize: 1000)
        XCTAssertEqual(r?.0, 900)
        XCTAssertEqual(r?.1, 999)
    }

    func testRejectsNonBytesUnit() {
        XCTAssertNil(RangeHeader.parse("items=0-1", totalSize: 1000))
    }

    func testRejectsZeroTotalSize() {
        XCTAssertNil(RangeHeader.parse("bytes=0-", totalSize: 0))
    }

    func testRejectsInvertedRange() {
        XCTAssertNil(RangeHeader.parse("bytes=500-100", totalSize: 1000))
    }
}
