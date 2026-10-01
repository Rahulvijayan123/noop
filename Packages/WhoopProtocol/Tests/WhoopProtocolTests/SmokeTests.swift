import XCTest
@testable import WhoopProtocol

final class SmokeTests: XCTestCase {
    func testSchemaResourceBundled() {
        XCTAssertNotNil(WhoopProtocolInfo.schemaResourceURL(),
                        "whoop_protocol.json must be bundled in the WhoopProtocol target")
    }
}
