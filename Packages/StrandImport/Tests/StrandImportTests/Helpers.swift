import XCTest
import Foundation
@testable import StrandImport

enum Fixtures {
    /// URL of a fixture file inside the test bundle's copied `Resources` dir.
    static func url(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> URL {
        // Resources were added with `.copy("Resources")`, so they live under a
        // "Resources" subdirectory of the bundle.
        if let u = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources") {
            return u
        }
        if let u = Bundle.module.url(forResource: name, withExtension: nil) {
            return u
        }
        XCTFail("Missing fixture: \(name)", file: file, line: line)
        return URL(fileURLWithPath: "/dev/null")
    }

    static func data(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> Data {
        let u = url(name, file: file, line: line)
        return (try? Data(contentsOf: u)) ?? Data()
    }

    /// A UTC `Date` from components, for assertions.
    static func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }
}
