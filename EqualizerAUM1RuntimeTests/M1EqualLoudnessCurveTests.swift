import Foundation
import XCTest

final class M1EqualLoudnessCurveTests: XCTestCase {
    func testOneKilohertzLevelTracksPhonWithinHalfDecibel() {
        for phon in stride(from: 20.0, through: 100.0, by: 20) {
            let level = M1EqualLoudnessCurve.soundPressureLevelDB(
                frequencyHz: 1_000,
                phon: phon
            )
            XCTAssertNotNil(level)
            XCTAssertEqual(abs(level! - phon), 0.5, accuracy: 0.5, "phon \(phon)")
        }
    }

    func testLowFrequencyContoursMatchPublishedAnchors() {
        // Hand-computed from the ISO 226:2003 fit (see ADR-0023 research).
        XCTAssertEqual(
            M1EqualLoudnessCurve.soundPressureLevelDB(frequencyHz: 20, phon: 20)!,
            89.6,
            accuracy: 1.0
        )
        XCTAssertEqual(
            M1EqualLoudnessCurve.soundPressureLevelDB(frequencyHz: 20, phon: 80)!,
            119.0,
            accuracy: 1.0
        )
        // Above threshold support only.
        XCTAssertNil(M1EqualLoudnessCurve.soundPressureLevelDB(frequencyHz: 20, phon: 0))
        XCTAssertNil(M1EqualLoudnessCurve.soundPressureLevelDB(frequencyHz: -1, phon: 60))
        XCTAssertNil(M1EqualLoudnessCurve.soundPressureLevelDB(frequencyHz: 100, phon: .nan))
    }

    func testCompensationIsNormalizedAtOneKilohertz() {
        let gain = M1EqualLoudnessCurve.compensationGainDB(
            frequencyHz: 1_000,
            referencePhon: 85,
            currentPhon: 65
        )
        XCTAssertNotNil(gain)
        XCTAssertEqual(gain!, 0, accuracy: 0.3)
    }

    func testQuieterListeningBoostsBassAndLouderCutsIt() {
        let quieter = M1EqualLoudnessCurve.compensationGainDB(
            frequencyHz: 20,
            referencePhon: 85,
            currentPhon: 65
        )!
        XCTAssertEqual(quieter, 10.5, accuracy: 1.5)

        let louder = M1EqualLoudnessCurve.compensationGainDB(
            frequencyHz: 20,
            referencePhon: 85,
            currentPhon: 105
        )!
        XCTAssertEqual(louder, -10.6, accuracy: 1.5)

        let mid = M1EqualLoudnessCurve.compensationGainDB(
            frequencyHz: 1_000,
            referencePhon: 85,
            currentPhon: 65
        )!
        let lowFrequency = quieter
        XCTAssertGreaterThan(lowFrequency, mid)
    }

    func testTargetCurveIsNullWhenLevelsMatchOrStrengthIsZero() {
        XCTAssertNil(
            M1EqualLoudnessCurve.compensationTargetGainDB(
                referencePhon: 85,
                currentPhon: 85,
                strength: 1
            )
        )
        XCTAssertNil(
            M1EqualLoudnessCurve.compensationTargetGainDB(
                referencePhon: 85,
                currentPhon: 65,
                strength: 0
            )
        )
    }

    func testTargetCurveClampsShiftsAndScales() {
        let curve = M1EqualLoudnessCurve.compensationTargetGainDB(
            referencePhon: 85,
            currentPhon: 25,
            strength: 1
        )
        XCTAssertNotNil(curve)
        // Shifted curves never amplify: the maximum equals 0 dB.
        var maximum = -Double.infinity
        for frequency in [20.0, 100, 1_000, 10_000, 12_500] {
            maximum = max(maximum, curve!(frequency))
        }
        XCTAssertEqual(maximum, 0, accuracy: 0.35)
        // The bass boost is clamped into the ±24 dB GraphicEQ domain.
        XCTAssertLessThanOrEqual(curve!(20) - maximum, 0.001)
        XCTAssertGreaterThanOrEqual(curve!(20), -24 - 0.001 - maximum)
    }

    func testTargetCurveStrengthScalesGains() {
        let full = M1EqualLoudnessCurve.compensationTargetGainDB(
            referencePhon: 85,
            currentPhon: 65,
            strength: 1
        )!
        let half = M1EqualLoudnessCurve.compensationTargetGainDB(
            referencePhon: 85,
            currentPhon: 65,
            strength: 0.5
        )!
        for frequency in [20.0, 100, 1_000] {
            XCTAssertEqual(half(frequency), full(frequency) / 2, accuracy: 0.01)
        }
    }

    func testTargetCurveHoldsEndpointValuesOutsideTableSupport() {
        let curve = M1EqualLoudnessCurve.compensationTargetGainDB(
            referencePhon: 85,
            currentPhon: 65,
            strength: 1
        )!
        XCTAssertEqual(curve(12_500), curve(20_000), accuracy: 0.001)
        XCTAssertEqual(curve(20), curve(10), accuracy: 0.001)
    }

    func testExtremeVolumeDropClampsToFloorContourInsteadOfDropping() {
        // A volume far below the reference drives currentPhon under the fit's
        // domain; the clamp freezes the curve at the floor contour instead of
        // returning nil (which would drop the whole node, ADR-0023).
        let frozen = M1EqualLoudnessCurve.compensationTargetGainDB(
            referencePhon: 85,
            currentPhon: M1EqualLoudnessCurve.minimumFittedPhon - 25,
            strength: 1
        )
        let atFloor = M1EqualLoudnessCurve.compensationTargetGainDB(
            referencePhon: 85,
            currentPhon: M1EqualLoudnessCurve.minimumFittedPhon,
            strength: 1
        )
        XCTAssertNotNil(frozen)
        XCTAssertNotNil(atFloor)
        for frequency in [20.0, 100, 1_000, 10_000] {
            XCTAssertEqual(frozen!(frequency), atFloor!(frequency), accuracy: 0.001)
        }

        // Both phon inputs clamp, so a wholly below-floor pair is flat (nil).
        XCTAssertNil(
            M1EqualLoudnessCurve.compensationTargetGainDB(
                referencePhon: -20,
                currentPhon: -30,
                strength: 1
            )
        )
    }
}
