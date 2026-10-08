import XCTest
@testable import StrandAnalytics

/// Producer → decoder roundtrip for `nights[].prv_nonlinear` (spec-02 §1, CONTRACT §5.3). The JSON is
/// the literal output of `features/prv_nonlinear.compute_night` (Python sidecar, NeuroKit2 0.2.13) on a
/// deterministic 1 210-interval gap-free night (seed 3, 950 ± 30 ms), so the Swift decoder is pinned to
/// what the producer actually emits.
final class SleepPrvNonlinearDecodeTests: XCTestCase {

    private let producerOutput = #"""
    {"config": {"dfa_order": 1, "dfa_overlap": false, "dfa_scales": [4, 16], "max_segments": 24, "min_segments": 3, "sampen_delay": 1, "sampen_dimension": 2, "sampen_tolerance_sd": 0.2, "segment_beats": 300, "splice_tolerance_s": 3.0, "time_budget_s": 60.0}, "dfa_alpha1": {"iqr": 0.03930006069463021, "median": 0.5880930516025431, "segments": 4}, "method_version": "prv-nonlinear-1", "neurokit2": "0.2.13", "notes": "Secondary optical pulse-rate-variability research statistics on equal-length gap-free segments; not ECG HRV and not a measure of autonomic disease, fitness or exercise thresholds.", "reasons": [], "sample_entropy": {"iqr": 0.04289445021366545, "median": 2.178548625815678, "segments": 4}, "secondary": true, "segments_available": 4, "segments_evaluated": 4, "segments_rejected": 0, "segments_used": 4, "source": "prv_optical", "status": "available"}
    """#

    func testDecodesTheProducerOutput() throws {
        let block = try JSONDecoder().decode(SleepPrvNonlinear.self, from: Data(producerOutput.utf8))
        XCTAssertEqual(block.status, .available)
        XCTAssertEqual(block.reasons, [])
        XCTAssertEqual(block.methodVersion, "prv-nonlinear-1")
        XCTAssertEqual(block.neurokit2, "0.2.13")
        XCTAssertEqual(block.source, "prv_optical")
        XCTAssertEqual(block.secondary, true)
        XCTAssertEqual(block.config?.segmentBeats, 300)
        XCTAssertEqual(block.config?.sampenDimension, 2)
        XCTAssertEqual(block.config?.sampenToleranceSd, 0.2)
        XCTAssertEqual(block.config?.dfaScales, [4, 16])
        XCTAssertEqual(block.config?.minSegments, 3)
        XCTAssertEqual(block.config?.dfaOverlap, false)
        XCTAssertEqual(block.config?.maxSegments, 24)
        XCTAssertEqual(block.segmentsUsed, 4)
        XCTAssertEqual(block.segmentsRejected, 0)
        XCTAssertEqual(block.segmentsAvailable, 4)
        XCTAssertEqual(block.segmentsEvaluated, 4)
        XCTAssertEqual(try XCTUnwrap(block.sampleEntropy?.median), 2.178548625815678, accuracy: 1e-15)
        XCTAssertEqual(block.sampleEntropy?.segments, 4)
        XCTAssertEqual(try XCTUnwrap(block.dfaAlpha1?.median), 0.5880930516025431, accuracy: 1e-15)
        XCTAssertEqual(try XCTUnwrap(block.dfaAlpha1?.iqr), 0.03930006069463021, accuracy: 1e-15)
    }

    func testWithheldBlockDecodesWithNullValues() throws {
        let json = #"{"status": "withheld", "reasons": ["insufficient_segments"], "method_version": "prv-nonlinear-1", "segments_used": 2, "segments_rejected": 0, "segments_available": 2, "segments_evaluated": 2, "sample_entropy": {"median": null, "iqr": null, "segments": 2}, "dfa_alpha1": {"median": null, "iqr": null, "segments": 2}}"#
        let block = try JSONDecoder().decode(SleepPrvNonlinear.self, from: Data(json.utf8))
        XCTAssertEqual(block.status, .withheld)
        XCTAssertEqual(block.reasons, ["insufficient_segments"])
        XCTAssertNil(block.sampleEntropy?.median)
        XCTAssertNil(block.dfaAlpha1?.median)
    }
}
