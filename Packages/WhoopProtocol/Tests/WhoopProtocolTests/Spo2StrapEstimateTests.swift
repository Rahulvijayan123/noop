import XCTest
@testable import WhoopProtocol

final class Spo2StrapEstimateTests: XCTestCase {
    func testOnlyInBandBytesAreReadings() {
        let aux = [
            V18AuxSample(ts: 100, auxByte82: 0),      // no estimate this second
            V18AuxSample(ts: 101, auxByte82: 69),     // diagnostic code
            V18AuxSample(ts: 102, auxByte82: 70),     // lowest percentage
            V18AuxSample(ts: 103, auxByte82: 97),
            V18AuxSample(ts: 104, auxByte82: 100),    // highest percentage
            V18AuxSample(ts: 105, auxByte82: 128),    // bit-7 saturation sentinel
            V18AuxSample(ts: 106, auxByte82: nil),
            V18AuxSample(ts: 107),
        ]
        XCTAssertEqual(Spo2StrapEstimate.readings(from: aux).map(\.percent), [70, 97, 100])
        XCTAssertEqual(Spo2StrapEstimate.readings(from: aux).map(\.ts), [102, 103, 104])
    }

    func testOneReadingPerSecondAndOldestFirst() {
        let aux = [
            V18AuxSample(ts: 12, auxByte82: 95),
            V18AuxSample(ts: 10, auxByte82: 96),
            V18AuxSample(ts: 12, auxByte82: 94),
        ]
        let readings = Spo2StrapEstimate.readings(from: aux)
        XCTAssertEqual(readings.map(\.ts), [10, 12])
        XCTAssertEqual(readings.count, 2)
    }

    func testPayloadRoundTrips() {
        for pct in [70, 93, 100] {
            XCTAssertEqual(Spo2StrapEstimate.percent(fromPayloadJSON: Spo2StrapEstimate.payloadJSON(percent: pct)), pct)
        }
    }

    func testPayloadRejectsAnythingThatIsNotAnInBandWholeNumber() {
        for json in ["", "{}", "{\"pct\":69}", "{\"pct\":101}", "{\"pct\":97.5}", "{\"pct\":true}",
                     "{\"pct\":\"97\"}", "[97]", "97", "{\"other\":97}"] {
            XCTAssertNil(Spo2StrapEstimate.percent(fromPayloadJSON: json), json)
        }
    }
}
