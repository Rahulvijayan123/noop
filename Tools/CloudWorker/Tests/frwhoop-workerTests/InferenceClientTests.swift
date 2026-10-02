import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import frwhoop_worker

/// InferenceClient: loopback-only policy, the closed failure taxonomy, the exact
/// sidecar HTTP contract shape, and the bounded deadline. Every network case runs
/// against a real 127.0.0.1 stub (or a real refused port), never a mock.
final class InferenceClientTests: XCTestCase {

    // MARK: - Helpers

    private func expectClientError(_ message: String, _ body: () throws -> Void) -> InferenceClientError? {
        do {
            try body()
            XCTFail("expected InferenceClientError: \(message)")
            return nil
        } catch let error as InferenceClientError {
            return error
        } catch {
            XCTFail("unexpected error type for \(message): \(error)")
            return nil
        }
    }

    private func client(_ url: String, timeoutMS: Int = 20_000) -> InferenceClient {
        InferenceClient(baseURL: URL(string: url)!, timeoutMS: timeoutMS)
    }

    private func hrvRequest() -> InferenceRequest {
        InferenceRequest(
            metric: "hrv",
            context: InferenceRequest.Context(
                userId: "11111111-1111-5111-8111-111111111111",
                deviceId: "22222222-2222-5222-8222-222222222222",
                intervalStartUTC: "2026-10-01T00:00:00Z",
                intervalEndUTC: "2026-10-01T08:00:00Z",
                ianaTimezone: "America/New_York",
                profileVersion: nil, configVersion: "cfg-1", correctionsVersion: nil),
            input: .object(["beats": .array([])]),
            provider: InferenceRequest.Provider(providerId: "production.runs.v1"))
    }

    private static let okBody = """
        {"status":"ok","metric":"hrv","provider_id":"production.runs.v1",
         "versions":{"adapter":"frwhoop.hrv.rmssd/1","preprocessing":"pp/1","dependency":"nk/0.2.13",
                     "config":"cfg-1","model":null},
         "input":{"sha256":"abc","refs":{"rows":10}},
         "result":{"value":42.5,"unit":"ms"},
         "interval":{"start_utc":"2026-10-01T00:00:00Z","end_utc":"2026-10-01T08:00:00Z"},
         "final_or_provisional":"provisional","coverage":{"pairs":30},"raw_scores":null,
         "diagnostics":{"n_clean":120},"runtime_ms":37}
        """

    // MARK: - Loopback-only policy

    func testLoopbackHostsAreAccepted() {
        for host in ["127.0.0.1", "127.0.0.2", "127.1.2.3", "localhost", "::1", "[::1]"] {
            XCTAssertTrue(InferenceEndpoint.isLoopbackHost(host), "\(host) must be loopback")
        }
    }

    func testNonLoopbackHostsAreRejected() {
        for host in ["10.0.0.5", "192.168.1.10", "8.8.8.8", "0.0.0.0", "example.com",
                     "127.0.0.1.example.com", "128.0.0.1", "127.0.0"] {
            XCTAssertFalse(InferenceEndpoint.isLoopbackHost(host), "\(host) must not be loopback")
        }
    }

    func testParseRefusesNonLoopbackHost() {
        let error = expectClientError("non-loopback") {
            _ = try InferenceEndpoint.parse("http://10.0.0.5:8787")
        }
        guard case .nonLoopbackURL(let host)? = error else {
            return XCTFail("expected nonLoopbackURL, got \(String(describing: error))")
        }
        XCTAssertEqual(host, "10.0.0.5")
    }

    func testParseAllowsNonLoopbackOnlyWithTheTestFlag() throws {
        let url = try InferenceEndpoint.parse("http://10.0.0.5:8787", allowNonLoopback: true)
        XCTAssertEqual(url.host, "10.0.0.5")
    }

    func testParseRejectsRelativeAndHostlessURLs() {
        for raw in ["127.0.0.1:8787", "ftp://127.0.0.1:8787", "not a url", "http://"] {
            XCTAssertNotNil(expectClientError("\(raw) must be refused") {
                _ = try InferenceEndpoint.parse(raw)
            }, "\(raw) must be refused")
        }
    }

    func testFromEnvironmentIsOffWhenUnsetEmptyOrWhitespace() throws {
        XCTAssertNil(try InferenceClient.fromEnvironment([:]))
        XCTAssertNil(try InferenceClient.fromEnvironment(["FRWHOOP_INFERENCE_URL": ""]))
        XCTAssertNil(try InferenceClient.fromEnvironment(["FRWHOOP_INFERENCE_URL": "   "]))
    }

    func testFromEnvironmentBuildsLoopbackClientAndReadsTimeout() throws {
        let built = try InferenceClient.fromEnvironment([
            "FRWHOOP_INFERENCE_URL": "http://127.0.0.1:8787",
            "FRWHOOP_INFERENCE_TIMEOUT_MS": "1500",
        ])
        let client = try XCTUnwrap(built)
        XCTAssertEqual(client.baseURL.absoluteString, "http://127.0.0.1:8787")
        XCTAssertEqual(client.timeoutMS, 1500)
    }

    func testFromEnvironmentRefusesNonLoopbackUnlessFlagged() throws {
        XCTAssertNotNil(expectClientError("refused without flag") {
            _ = try InferenceClient.fromEnvironment(["FRWHOOP_INFERENCE_URL": "http://10.0.0.5:8787"])
        })
        let flagged = try InferenceClient.fromEnvironment([
            "FRWHOOP_INFERENCE_URL": "http://10.0.0.5:8787",
            InferenceEndpoint.allowNonLoopbackEnvKey: "1",
        ])
        XCTAssertNotNil(flagged)
    }

    func testOffModeMakesZeroRequests() throws {
        // The off switch is a nil client, so nothing can reach a server.
        let server = StubHTTPServer { _ in .json("{\"status\":\"ok\"}") }
        defer { server.stop() }
        let off = try InferenceClient.fromEnvironment(["FRWHOOP_INFERENCE_URL": ""])
        XCTAssertNil(off)
        XCTAssertEqual(server.requestCount, 0, "an off candidate lane must issue zero sidecar calls")
    }

    // MARK: - Request shape (contract)

    func testRequestEncodesTheContractExactly() throws {
        let data = try hrvRequest().canonicalJSON()
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["metric"] as? String, "hrv")
        let context = try XCTUnwrap(object["context"] as? [String: Any])
        XCTAssertEqual(context["user_id"] as? String, "11111111-1111-5111-8111-111111111111")
        XCTAssertEqual(context["device_id"] as? String, "22222222-2222-5222-8222-222222222222")
        XCTAssertEqual(context["interval_start_utc"] as? String, "2026-10-01T00:00:00Z")
        XCTAssertEqual(context["interval_end_utc"] as? String, "2026-10-01T08:00:00Z")
        XCTAssertEqual(context["iana_timezone"] as? String, "America/New_York")
        XCTAssertEqual(context["config_version"] as? String, "cfg-1")
        // The contract lists all eight context keys: absent ones are explicit nulls.
        XCTAssertTrue(context.keys.contains("profile_version"))
        XCTAssertTrue(context.keys.contains("corrections_version"))
        XCTAssertTrue(context["profile_version"] is NSNull)
        let provider = try XCTUnwrap(object["provider"] as? [String: Any])
        XCTAssertEqual(provider["provider_id"] as? String, "production.runs.v1")
        XCTAssertNotNil(object["input"] as? [String: Any])
    }

    func testRequestIsSentToV1InferAsPOST() throws {
        let server = StubHTTPServer { _ in .json(InferenceClientTests.okBody) }
        defer { server.stop() }
        _ = try client(server.baseURL).infer(hrvRequest())
        XCTAssertEqual(server.requestCount, 1)
        let served = try XCTUnwrap(server.servedRequests.first)
        XCTAssertEqual(served.method, "POST")
        XCTAssertEqual(served.path, "/v1/infer")
        XCTAssertEqual(served.headers["content-type"], "application/json")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: served.body) as? [String: Any])
        XCTAssertEqual(body["metric"] as? String, "hrv")
    }

    func testBasePathIsPreservedWhenBuildingEndpoints() throws {
        let server = StubHTTPServer { _ in .json(InferenceClientTests.okBody) }
        defer { server.stop() }
        _ = try client(server.baseURL + "/sidecar").infer(hrvRequest())
        XCTAssertEqual(server.servedRequests.first?.path, "/sidecar/v1/infer")
    }

    // MARK: - Success decoding

    func testInferDecodesOKResponse() throws {
        let server = StubHTTPServer { _ in .json(InferenceClientTests.okBody) }
        defer { server.stop() }
        let response = try client(server.baseURL).infer(hrvRequest())
        XCTAssertTrue(response.isOK)
        XCTAssertEqual(response.result?.value, 42.5)
        XCTAssertEqual(response.result?.unit, "ms")
        XCTAssertEqual(response.versions?.dependency, "nk/0.2.13")
        XCTAssertEqual(response.runtimeMs, 37)
        XCTAssertEqual(response.finalOrProvisional, "provisional")
    }

    func testHealthzDecodesReadiness() throws {
        let server = StubHTTPServer { _ in .json("""
            {"ready":true,"providers":{"production.runs.v1":{"ready":true,"version":"1.0","reason":null},
                                       "neurokit2.shadow.v1":{"ready":false,"version":"1.0","reason":"blocked_artifact"}}}
            """) }
        defer { server.stop() }
        let health = try client(server.baseURL).healthz()
        XCTAssertTrue(health.ready)
        XCTAssertEqual(health.readyProviderNames, ["production.runs.v1"])
        XCTAssertEqual(health.providers?["neurokit2.shadow.v1"]?.reason, "blocked_artifact")
        XCTAssertEqual(server.servedRequests.first?.path, "/healthz")
    }

    func testProvidersManifestAcceptsListAndObjectShapes() throws {
        let listServer = StubHTTPServer { _ in .json("""
            {"providers":[{"metric":"hrv","provider_id":"production.runs.v1","behavior":"retrospective",
                           "eligibility":"eligible","label_space":null}]}
            """) }
        defer { listServer.stop() }
        let list = try client(listServer.baseURL).providers()
        XCTAssertEqual(list.providers.count, 1)
        XCTAssertEqual(list.providers.first?.providerId, "production.runs.v1")

        let objectServer = StubHTTPServer { _ in .json("""
            {"providers":{"production.runs.v1":{"metric":"hrv","eligibility":"eligible"}}}
            """) }
        defer { objectServer.stop() }
        let byID = try client(objectServer.baseURL).providers()
        XCTAssertEqual(byID.providers.first?.providerId, "production.runs.v1")
    }

    // MARK: - Failure taxonomy

    func testRefusedConnectionIsClassifiedAsProviderError() {
        let url = "http://127.0.0.1:\(closedLoopbackPort())"
        let error = expectClientError("refused") { _ = try self.client(url, timeoutMS: 3_000).infer(self.hrvRequest()) }
        guard case .refused? = error else { return XCTFail("expected refused, got \(String(describing: error))") }
        XCTAssertEqual(error?.withheldReason, .providerError)
    }

    func testTimeoutIsBoundedAndClassifiedAsTimeout() {
        let server = StubHTTPServer { _ in
            var response = StubHTTPServer.Response()
            response.neverRespond = true
            return response
        }
        defer { server.stop() }
        let started = Date()
        let error = expectClientError("timeout") {
            _ = try self.client(server.baseURL, timeoutMS: 700).infer(self.hrvRequest())
        }
        let elapsed = Date().timeIntervalSince(started)
        guard case .timeout? = error else { return XCTFail("expected timeout, got \(String(describing: error))") }
        XCTAssertEqual(error?.withheldReason, .timeout)
        // Bounded: the call must not wait for the stub's own 10 s socket timeout.
        XCTAssertLessThan(elapsed, 6.0, "the client deadline must bound the wait (took \(elapsed)s)")
    }

    func testNon200IsClassifiedAsProviderError() {
        let server = StubHTTPServer { _ in .json("{\"error\":\"boom\"}", status: 500) }
        defer { server.stop() }
        let error = expectClientError("non-200") { _ = try self.client(server.baseURL).infer(self.hrvRequest()) }
        guard case .non200(let code, _)? = error else {
            return XCTFail("expected non200, got \(String(describing: error))")
        }
        XCTAssertEqual(code, 500)
        XCTAssertEqual(error?.withheldReason, .providerError)
    }

    func testNotReady503IsClassifiedAsNotReady() {
        let server = StubHTTPServer { _ in
            .json("{\"error\":\"provider_not_ready\",\"reason\":\"not_ready\"}", status: 503)
        }
        defer { server.stop() }
        let error = expectClientError("503") { _ = try self.client(server.baseURL).infer(self.hrvRequest()) }
        guard case .notReady? = error else { return XCTFail("expected notReady, got \(String(describing: error))") }
        XCTAssertEqual(error?.withheldReason, .notReady)
    }

    func testMalformedBodyIsClassifiedAsMalformed() {
        let server = StubHTTPServer { _ in .json("this is not json") }
        defer { server.stop() }
        let error = expectClientError("malformed") { _ = try self.client(server.baseURL).infer(self.hrvRequest()) }
        guard case .malformed? = error else { return XCTFail("expected malformed, got \(String(describing: error))") }
        XCTAssertEqual(error?.withheldReason, .providerError)
    }

    func testUnknownStatusIsMalformed() {
        let server = StubHTTPServer { _ in .json("{\"status\":\"banana\"}") }
        defer { server.stop() }
        XCTAssertNotNil(expectClientError("unknown status") { _ = try self.client(server.baseURL).infer(self.hrvRequest()) })
    }

    func testWithheldWithoutReasonIsMalformed() {
        let server = StubHTTPServer { _ in .json("{\"status\":\"withheld\",\"metric\":\"hrv\"}") }
        defer { server.stop() }
        XCTAssertNotNil(expectClientError("withheld without reason") {
            _ = try self.client(server.baseURL).infer(self.hrvRequest())
        })
    }

    func testOKWithoutResultIsMalformed() {
        let server = StubHTTPServer { _ in .json("{\"status\":\"ok\",\"metric\":\"hrv\"}") }
        defer { server.stop() }
        XCTAssertNotNil(expectClientError("ok without result") {
            _ = try self.client(server.baseURL).infer(self.hrvRequest())
        })
    }

    func testMetricMismatchIsMalformed() {
        let server = StubHTTPServer { _ in .json("""
            {"status":"ok","metric":"sleep_stage","result":{"value":1.0,"unit":"ms"}}
            """) }
        defer { server.stop() }
        XCTAssertNotNil(expectClientError("metric mismatch") {
            _ = try self.client(server.baseURL).infer(self.hrvRequest())
        })
    }

    func testOversizedBodyIsRejectedBeforeDecoding() {
        let server = StubHTTPServer { _ in .json(String(repeating: "a", count: 4096)) }
        defer { server.stop() }
        let tiny = InferenceClient(baseURL: URL(string: server.baseURL)!, timeoutMS: 5_000, maxResponseBytes: 64)
        XCTAssertNotNil(expectClientError("oversized") { _ = try tiny.infer(self.hrvRequest()) })
    }

    func testWithheldReasonFallsBackToDiagnosticsKeys() {
        // The plan fixes the reason VOCABULARY, not the key: accept the documented
        // top-level key and the diagnostics shapes.
        let topLevel = try? JSONDecoder().decode(InferenceResponse.self, from: Data("""
            {"status":"withheld","withheld_reason":"insufficient_coverage"}
            """.utf8))
        XCTAssertEqual(topLevel?.withheldReason, "insufficient_coverage")
        let nested = try? JSONDecoder().decode(InferenceResponse.self, from: Data("""
            {"status":"withheld","diagnostics":{"reason":"blocked_input"}}
            """.utf8))
        XCTAssertEqual(nested?.withheldReason, "blocked_input")
    }

    func testWithheldReasonsAreAClosedSet() {
        // Every client-produced failure settles as one of the three client reasons.
        let clientReasons: [InferenceClientError] = [
            .refused("x"), .timeout("x"), .non200(500, "x"), .malformed("x"),
            .transport("x"), .disabled, .nonLoopbackURL("x"),
        ]
        for error in clientReasons {
            let reason = error.withheldReason
            XCTAssertTrue(reason.isClientFailure, "\(error) must settle as a client failure reason")
            XCTAssertNotNil(CandidateWithheldReason(rawValue: reason.rawValue))
        }
        XCTAssertEqual(InferenceClientError.notReady("x").withheldReason, .notReady)
    }

    func testRetryPolicyIsBoundedToTransientFailures() {
        XCTAssertTrue(CandidateStage.isRetryable(.timeout("x")))
        XCTAssertTrue(CandidateStage.isRetryable(.refused("x")))
        XCTAssertTrue(CandidateStage.isRetryable(.transport("x")))
        XCTAssertTrue(CandidateStage.isRetryable(.notReady("x")))
        XCTAssertFalse(CandidateStage.isRetryable(.non200(500, "x")))
        XCTAssertFalse(CandidateStage.isRetryable(.malformed("x")))
    }

    // MARK: - Digests

    func testInputDigestIsStableAcrossKeyOrder() throws {
        let a = JSONValue(any: ["b": 1, "a": [1, 2, 3]] as [String: Any])
        let b = JSONValue(any: ["a": [1, 2, 3], "b": 1] as [String: Any])
        let digestA = try InferenceClient.inputDigest(a)
        XCTAssertEqual(digestA, try InferenceClient.inputDigest(b))
        XCTAssertEqual(digestA.count, 64)
        XCTAssertTrue(digestA.allSatisfy { $0.isHexDigit })
    }

    func testInputDigestChangesWithContent() throws {
        let a = try InferenceClient.inputDigest(.object(["beats": .array([])]))
        let b = try InferenceClient.inputDigest(.object(["beats": .array([.int(1)])]))
        XCTAssertNotEqual(a, b)
    }
}
