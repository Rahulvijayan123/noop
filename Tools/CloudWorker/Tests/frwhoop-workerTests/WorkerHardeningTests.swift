import XCTest
@testable import frwhoop_worker

/// F6/F7/F8 unit tests for the worker hardening that can be checked without a
/// database: TLS/connection-string enforcement, error classification, health-row
/// identifier normalisation, and the boolean parsing the fenced RPCs need.
final class WorkerHardeningTests: XCTestCase {

    // MARK: - F6 TLS / connection options

    private func options(_ env: [String: String]) throws -> PostgresOptions {
        var base = ["FRWHOOP_DB_URL": "postgresql://u:p@db.example.com:5432/postgres"]
        base.merge(env) { _, new in new }
        return try PostgresOptions.fromEnvironment(base)
    }

    func testDefaultSSLModesIsVerifyFull() throws {
        let o = try options([:])
        XCTAssertEqual(o.sslMode, "verify-full")
        XCTAssertFalse(o.allowInsecure)
    }

    func testWeakSSLModesAreRefused() throws {
        for mode in ["disable", "allow", "prefer", "require"] {
            XCTAssertThrowsError(try options(["FRWHOOP_DB_SSLMODE": mode]),
                                 "sslmode=\(mode) must be refused: it does not authenticate the server")
        }
    }

    func testVerifyCAIsAccepted() throws {
        let o = try options(["FRWHOOP_DB_SSLMODE": "verify-ca"])
        XCTAssertEqual(o.sslMode, "verify-ca")
    }

    func testInsecureOverrideIsTheOnlyEscape() throws {
        let o = try options(["FRWHOOP_DB_SSLMODE": "disable", "FRWHOOP_ALLOW_INSECURE_DB": "1"])
        XCTAssertEqual(o.sslMode, "disable")
        XCTAssertTrue(o.allowInsecure)
    }

    func testExplicitCARootCertIsUsed() throws {
        let o = try options(["FRWHOOP_DB_SSLROOTCERT": "/etc/frwhoop/supabase-ca.pem"])
        XCTAssertEqual(o.sslRootCert, "/etc/frwhoop/supabase-ca.pem")
    }

    /// The worker must not silently inherit a caller's plaintext sslmode from the
    /// URL: `resolvedParameters` drops it and re-adds the enforced one.
    func testResolvedParametersForceTLSOverURL() throws {
        var env = ["FRWHOOP_DB_URL": "postgresql://u:p@db.example.com:5432/postgres?sslmode=disable&application_name=other"]
        env["FRWHOOP_DB_SSLROOTCERT"] = "/etc/frwhoop/supabase-ca.pem"
        let o = try PostgresOptions.fromEnvironment(env)
        let pairs = try PostgresClient.resolvedParameters(o)
        let dict = Dictionary(pairs, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(dict["sslmode"], "verify-full", "a plaintext sslmode in the URL must be overridden")
        XCTAssertEqual(dict["sslrootcert"], "/etc/frwhoop/supabase-ca.pem")
        XCTAssertEqual(dict["application_name"], "frwhoop-worker", "application_name must identify the worker backend")
        XCTAssertEqual(dict["host"], "db.example.com")
        XCTAssertEqual(dict["port"], "5432")
        XCTAssertEqual(dict["keepalives"], "1")
    }

    /// A CA path with a space must survive: the values are handed to
    /// PQconnectdbParams, not pasted into a URI.
    func testResolvedParametersHandleSpacesInPaths() throws {
        var env = ["FRWHOOP_DB_URL": "postgresql://u:p@db.example.com/postgres"]
        env["FRWHOOP_DB_SSLROOTCERT"] = "/Volumes/External SSD/ca.pem"
        env["FRWHOOP_WORKER_NAME"] = "worker-2"
        let o = try PostgresOptions.fromEnvironment(env)
        let dict = Dictionary(try PostgresClient.resolvedParameters(o), uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(dict["sslrootcert"], "/Volumes/External SSD/ca.pem")
        XCTAssertEqual(dict["application_name"], "frwhoop-worker:worker-2")
    }

    func testKeywordValueConnectionStringIsAccepted() throws {
        let o = try PostgresOptions.fromEnvironment([
            "FRWHOOP_DB_URL": "host=db.example.com port=5432 dbname=postgres user=u password=p sslmode=disable",
        ])
        let dict = Dictionary(try PostgresClient.resolvedParameters(o), uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(dict["sslmode"], "verify-full")
        XCTAssertEqual(dict["dbname"], "postgres")
    }

    func testMalformedConnectionStringIsRejected() throws {
        let o = try PostgresOptions.fromEnvironment(["FRWHOOP_DB_URL": "not a conninfo at all!!"])
        XCTAssertThrowsError(try PostgresClient.resolvedParameters(o))
    }

    // MARK: - F8 error classification

    func testSerializationAndDeadlockAreRetryable() {
        XCTAssertEqual(PostgresClient.kind(forSQLState: "40001"), .serialization)
        XCTAssertEqual(PostgresClient.kind(forSQLState: "40P01"), .serialization)
    }

    func testConnectionExceptionsAreConnectionLost() {
        for state in ["08000", "08003", "08006", "57P01", "57P02", "57P03"] {
            XCTAssertEqual(PostgresClient.kind(forSQLState: state), .connectionLost, state)
        }
    }

    func testAbortedTransactionIsItsOwnClass() {
        XCTAssertEqual(PostgresClient.kind(forSQLState: "25P02"), .aborted)
    }

    func testStaleLeaseMarkerIsStale() {
        // engine_publish_legacy_fenced re-raises a serialization failure as PT409.
        XCTAssertEqual(PostgresClient.kind(forSQLState: "PT409"), .stale)
    }

    func testDeterministicFailuresAreNotRetried() {
        for state in ["23514", "23505", "23503", "22007", "42501"] {
            XCTAssertEqual(PostgresClient.kind(forSQLState: state), .deterministic, state)
        }
    }

    func testUnknownStateIsOther() {
        XCTAssertEqual(PostgresClient.kind(forSQLState: nil), .other)
        XCTAssertEqual(PostgresClient.kind(forSQLState: ""), .other)
        XCTAssertEqual(PostgresClient.kind(forSQLState: "XX000"), .other)
    }

    func testErrorDescriptionCarriesTheClass() {
        let e = PostgresClient.Error(message: "boom", sqlstate: "40001", kind: .serialization)
        XCTAssertTrue(e.description.contains("40001"))
        XCTAssertTrue(e.description.contains("serialization"))
    }

    // MARK: - Fenced-RPC boolean parsing

    func testIsTrueAcceptsPostgresBooleans() {
        for yes in ["true", "t", "TRUE", " true ", "1"] {
            XCTAssertTrue(isTrue(yes), yes)
        }
        for no in ["false", "f", "FALSE", "", "0", "null"] {
            XCTAssertFalse(isTrue(no), no)
        }
        XCTAssertFalse(isTrue(nil), "a missing result must never read as success")
    }

    // MARK: - F7 health-row identifier normalisation

    func testNormalizedRevisionPassesThroughRealSHAs() {
        let sha = "991f9a7ea0fd74fc9cef7d4f41ec1ab3f00cb46c"
        XCTAssertEqual(normalizedRevision(sha), sha)
        XCTAssertEqual(normalizedRevision(sha.uppercased()), sha)
    }

    /// physiology_worker_heartbeats.source_revision is CHECKed against
    /// ^[0-9a-f]{40}$, so "unknown" must still produce a valid value.
    func testNormalizedRevisionMakesPlaceholdersValid() {
        let out = normalizedRevision("unknown")
        XCTAssertEqual(out.count, 40)
        XCTAssertTrue(out.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(out, normalizedRevision("unknown"), "must be deterministic")
        XCTAssertNotEqual(out, normalizedRevision("other"))
    }

    func testStableInstanceUUIDIsAStableNonZeroUUID() {
        let a = stableInstanceUUID("frwhoop-worker-2")
        let b = stableInstanceUUID("frwhoop-worker-2")
        let c = stableInstanceUUID("frwhoop-worker-3")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(a, "00000000-0000-0000-0000-000000000000")
        XCTAssertNotNil(UUID(uuidString: a), "must parse as a UUID: \(a)")
        XCTAssertEqual(a.count, 36)
        XCTAssertEqual(a.split(separator: "-").map(\.count), [8, 4, 4, 4, 12])
    }

    /// physiology_worker_heartbeats.last_error is CHECKed against
    /// ^[A-Za-z][A-Za-z0-9_.:-]{0,127}$.
    func testHealthErrorIsSanitizedToTheColumnContract() {
        let raw = "retryable(\"non-projectable kind/format physiology/ndjson_gzip_v3\")"
        let out = sanitizedHealthError(raw)
        XCTAssertNotNil(out)
        let value = out!
        XCTAssertLessThanOrEqual(value.count, 127)
        XCTAssertTrue(value.first!.isLetter)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:-")
        XCTAssertTrue(value.unicodeScalars.allSatisfy { allowed.contains($0) }, value)
    }

    func testHealthErrorIsNilWhenThereIsNoError() {
        XCTAssertNil(sanitizedHealthError(nil))
        XCTAssertNil(sanitizedHealthError(""))
    }

    func testHealthErrorIsNilWhenItCannotStartWithALetter() {
        XCTAssertNil(sanitizedHealthError("((((("))
    }

    // MARK: - Lane independence plumbing

    func testLaneSnapshotIsReadableAcrossThreads() {
        let state = LaneState(LaneSnapshot(name: "scoring", enabled: true))
        let group = DispatchGroup()
        for i in 0..<50 {
            group.enter()
            DispatchQueue.global().async {
                state.update { $0.counters["completed"] = i }
                group.leave()
            }
        }
        group.wait()
        XCTAssertNotNil(state.read().counters["completed"])
    }

    func testShutdownFlagIsVisibleAcrossThreads() {
        let flag = ShutdownFlag()
        XCTAssertFalse(flag.isSet)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            flag.set()
            group.leave()
        }
        group.wait()
        XCTAssertTrue(flag.isSet)
    }
}
