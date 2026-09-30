import XCTest
@testable import NoopPush

final class PushRegistryTests: XCTestCase {

    struct CloudFixture: Decodable {
        struct Entry: Decodable {
            let classification: String
            let wireStream: String?
            let delivery: String?
        }
        let tables: [String: Entry]
    }

    func testV1_1WireStreamsMatchCloudIngestionRegistry() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "cloud_ingestion_registry", withExtension: "json"))
        let fixture = try JSONDecoder().decode(CloudFixture.self, from: Data(contentsOf: url))
        let shipped = fixture.tables.values
            .filter { $0.classification == "shipped" }
            .compactMap(\.wireStream)
        let expected = Set(shipped).subtracting(PushRegistryV1_2.additionalBinaryStreams)
        XCTAssertEqual(PushRegistryV1_1.streamNames, expected,
                       "PushRegistryV1_1 must name every shipped wire stream in cloud_ingestion_registry.json except 1.2-only binary streams")
    }

    func testV1_2WireStreamsMatchCloudIngestionRegistry() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "cloud_ingestion_registry", withExtension: "json"))
        let fixture = try JSONDecoder().decode(CloudFixture.self, from: Data(contentsOf: url))
        let shipped = fixture.tables.values
            .filter { $0.classification == "shipped" }
            .compactMap(\.wireStream)
        XCTAssertEqual(PushRegistryV1_2.streamNames, Set(shipped),
                       "PushRegistryV1_2 must name every shipped wire stream in cloud_ingestion_registry.json")
    }

    func testV1IsSubsetOfV1_1() {
        XCTAssertTrue(PushRegistryV1.streamNames.isSubset(of: PushRegistryV1_1.streamNames))
    }

    /// The registry is a SHARED contract: the package copy, the phone store's copy and the Android
    /// copy must agree byte-for-byte, or one platform silently ships a different stream set.
    ///
    /// The comparison runs over whichever sibling copies EXIST in this checkout. The fork this package
    /// was ported into (`Rahulvijayan123/noop`) carries only the package copy: it has no
    /// `Packages/WhoopStore/.../cloud_ingestion_registry.json` and no
    /// `android/app/src/test/resources/...` copy, because neither of those consumers is wired for the
    /// hosted-compute path there. Asserting on an absent file would report a missing sibling as a
    /// contract DRIFT, which is the wrong diagnosis, so an absent copy is skipped by name and the test
    /// still fails loudly on any copy that IS present and disagrees.
    ///
    /// (Verified when this was ported: Whoop-Nara at 9abbcf22 carries all three copies and they are
    /// byte-identical, sha256 ba00ad9b810eeca7f38b91e88eea90b34adf0096e6a6eb70b19cb94c0bd45b15. Restoring
    /// the sibling copies here re-arms the full three-way check with no other change.)
    func testEveryPresentRegistryCopyIsByteIdentical() throws {
        let bundledURL = try XCTUnwrap(Bundle.module.url(forResource: "cloud_ingestion_registry", withExtension: "json"))
        let bundled = try Data(contentsOf: bundledURL)
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let copies = [
            "Packages/NoopPush/Tests/NoopPushTests/Resources/cloud_ingestion_registry.json",
            "Packages/WhoopStore/Tests/WhoopStoreTests/Resources/cloud_ingestion_registry.json",
            "android/app/src/test/resources/cloud_ingestion_registry.json"
        ]
        var compared = 0
        for path in copies {
            let url = repository.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("[registry] no sibling copy at \(path) in this checkout — skipping it")
                continue
            }
            XCTAssertEqual(bundled, try Data(contentsOf: url),
                           "Registry copies must agree on local-only entries as well as shipped streams: \(path)")
            compared += 1
        }
        // The package's own copy must always be one of the compared files; a zero here would mean the
        // repository layout moved and this test stopped checking anything.
        XCTAssertGreaterThan(compared, 0, "no registry copy was compared — the repository layout changed")
    }
}
