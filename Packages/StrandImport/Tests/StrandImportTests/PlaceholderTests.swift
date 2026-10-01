import XCTest
@testable import StrandImport

final class PlaceholderTests: XCTestCase {
    func testVersion() { XCTAssertEqual(StrandImport.version, "0.1.0") }
}
