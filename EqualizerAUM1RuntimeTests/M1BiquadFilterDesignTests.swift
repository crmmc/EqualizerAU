import Foundation
import XCTest

final class M1BiquadFilterDesignTests: XCTestCase {
    // MARK: - Response properties per filter type (RBJ parity)

    func testPeakingMatchesGainAtCenterFrequency() throws {
        let specification = M1FilterSpecification(
            type: .peaking,
            frequencyHz: 1_000,
            gainDB: 6,
            width: .q(2.5),
            cornerFrequency: false
        )
        let coefficients = try designCoefficients(specification, sampleRate: 48_000)
        let response = Self.responseDB(coefficients, frequencyHz: 1_000, sampleRate: 48_000)
        XCTAssertEqual(response, 6, accuracy: 0.01)
        let flat = Self.responseDB(coefficients, frequencyHz: 40, sampleRate: 48_000)
        XCTAssertEqual(flat, 0, accuracy: 0.01)
    }

    func testLowPassAttenuatesTowardNyquistAndPassesDC() throws {
        let specification = M1FilterSpecification(
            type: .lowPass,
            frequencyHz: 1_000,
            gainDB: 0,
            width: .q(1.0 / 2.0.squareRoot()),
            cornerFrequency: false
        )
        let coefficients = try designCoefficients(specification, sampleRate: 48_000)
        XCTAssertEqual(
            Self.responseDB(coefficients, frequencyHz: 20, sampleRate: 48_000),
            0,
            accuracy: 0.01
        )
        let nyquistResponse = Self.responseDB(
            coefficients,
            frequencyHz: 23_000,
            sampleRate: 48_000
        )
        XCTAssertLessThan(nyquistResponse, -40)
        // Butterworth low-pass is −3 dB at the corner.
        XCTAssertEqual(
            Self.responseDB(coefficients, frequencyHz: 1_000, sampleRate: 48_000),
            -3.01,
            accuracy: 0.15
        )
    }

    func testHighPassMirrorsLowPassAsymptotes() throws {
        let specification = M1FilterSpecification(
            type: .highPass,
            frequencyHz: 1_000,
            gainDB: 0,
            width: .q(1.0 / 2.0.squareRoot()),
            cornerFrequency: false
        )
        let coefficients = try designCoefficients(specification, sampleRate: 48_000)
        XCTAssertLessThan(
            Self.responseDB(coefficients, frequencyHz: 20, sampleRate: 48_000),
            -40
        )
        XCTAssertEqual(
            Self.responseDB(coefficients, frequencyHz: 18_000, sampleRate: 48_000),
            0,
            accuracy: 0.01
        )
    }

    func testBandPassPassesCenterFrequencyAtUnity() throws {
        let specification = M1FilterSpecification(
            type: .bandPass,
            frequencyHz: 1_000,
            gainDB: 0,
            width: .q(1),
            cornerFrequency: false
        )
        let coefficients = try designCoefficients(specification, sampleRate: 48_000)
        XCTAssertEqual(
            Self.responseDB(coefficients, frequencyHz: 1_000, sampleRate: 48_000),
            0,
            accuracy: 0.01
        )
        let suppressed = Self.responseDB(coefficients, frequencyHz: 40, sampleRate: 48_000)
        XCTAssertLessThan(suppressed, -20)
    }

    func testNotchNullsCenterFrequency() throws {
        let specification = M1FilterSpecification(
            type: .notch,
            frequencyHz: 800,
            gainDB: 0,
            width: .q(30),
            cornerFrequency: false
        )
        let coefficients = try designCoefficients(specification, sampleRate: 48_000)
        XCTAssertLessThan(
            Self.responseDB(coefficients, frequencyHz: 800, sampleRate: 48_000),
            -100
        )
        XCTAssertEqual(
            Self.responseDB(coefficients, frequencyHz: 10_000, sampleRate: 48_000),
            0,
            accuracy: 0.01
        )
    }

    func testAllPassKeepsUnityMagnitudeAtEveryFrequency() throws {
        let specification = M1FilterSpecification(
            type: .allPass,
            frequencyHz: 900,
            gainDB: 0,
            width: .q(0.7071),
            cornerFrequency: false
        )
        let coefficients = try designCoefficients(specification, sampleRate: 48_000)
        for frequencyHz in [90.0, 900.0, 4_500.0, 18_000.0] {
            XCTAssertEqual(
                Self.responseDB(coefficients, frequencyHz: frequencyHz, sampleRate: 48_000),
                0,
                accuracy: 1e-6
            )
        }
    }

    func testCenterFrequencyShelfHasHalfGainAtCenter() throws {
        // LSC/HSC semantics: Fc is the center frequency where gain is half.
        let specification = M1FilterSpecification(
            type: .lowShelf,
            frequencyHz: 300,
            gainDB: 8,
            width: .q(0.6473),
            cornerFrequency: false
        )
        let coefficients = try designCoefficients(specification, sampleRate: 48_000)
        XCTAssertEqual(
            Self.responseDB(coefficients, frequencyHz: 300, sampleRate: 48_000),
            4,
            accuracy: 0.05
        )
        XCTAssertEqual(
            Self.responseDB(coefficients, frequencyHz: 20, sampleRate: 48_000),
            8,
            accuracy: 0.05
        )
        XCTAssertEqual(
            Self.responseDB(coefficients, frequencyHz: 10_000, sampleRate: 48_000),
            0,
            accuracy: 0.05
        )
    }

    func testCornerFrequencyShelfShiftsCenterByReferenceFactor() throws {
        // Reference BiQuadFilter.cpp: corner-frequency shelves multiply the low
        // shelf center by `10^(|gain| / 80 / S)`, high shelves divide.
        let gainDB = 7.2
        let slopeDBPerOctave = 10.8
        let frequencyHz = 50.0
        let specification = M1FilterSpecification(
            type: .lowShelf,
            frequencyHz: frequencyHz,
            gainDB: gainDB,
            width: .slopeDBPerOctave(slopeDBPerOctave),
            cornerFrequency: true
        )
        let amplitude = pow(10.0, gainDB / 40.0)
        let s = slopeDBPerOctave / 12.0
        let factor = pow(10.0, abs(gainDB) / 80.0 / s)
        let centerFrequency = frequencyHz * factor

        let coefficients = try designCoefficients(specification, sampleRate: 48_000)
        XCTAssertEqual(
            Self.responseDB(coefficients, frequencyHz: centerFrequency, sampleRate: 48_000),
            gainDB / 2,
            accuracy: 0.05
        )
        // A center-frequency shelf with the same parameters puts the half-gain
        // point at Fc itself instead.
        let centerSpecification = M1FilterSpecification(
            type: .lowShelf,
            frequencyHz: frequencyHz,
            gainDB: gainDB,
            width: .slopeDBPerOctave(slopeDBPerOctave),
            cornerFrequency: false
        )
        let centerCoefficients = try designCoefficients(centerSpecification, sampleRate: 48_000)
        XCTAssertEqual(
            Self.responseDB(centerCoefficients, frequencyHz: frequencyHz, sampleRate: 48_000),
            gainDB / 2,
            accuracy: 0.05
        )
        XCTAssertEqual(amplitude, pow(10.0, gainDB / 40.0), accuracy: 1e-12)
    }

    func testBandwidthWidthChangesPeakingSharpness() throws {
        func peakingResponse(_ width: M1FilterWidth) throws -> Double {
            let specification = M1FilterSpecification(
                type: .peaking,
                frequencyHz: 1_000,
                gainDB: 12,
                width: width,
                cornerFrequency: false
            )
            let coefficients = try designCoefficients(specification, sampleRate: 48_000)
            return Self.responseDB(coefficients, frequencyHz: 500, sampleRate: 48_000)
        }
        // One octave below center, a sharp (high-Q) peak has rolled off far
        // more than a wide 2-octave peak.
        let sharp = try peakingResponse(.q(10))
        let wide = try peakingResponse(.bandwidthOctaves(2))
        XCTAssertGreaterThan(wide, 3)
        XCTAssertLessThan(sharp, wide - 3)
    }

    // MARK: - Bypass reasons

    func testFrequencyAtOrAboveNyquistBypasses() {
        let specification = M1FilterSpecification(
            type: .peaking,
            frequencyHz: 10_000,
            gainDB: 3,
            width: .q(1),
            cornerFrequency: false
        )
        let outcome = M1BiquadFilterDesign.design(specification: specification, sampleRate: 16_000)
        XCTAssertEqual(outcome, .bypass(.frequencyAtOrAboveNyquist))
    }

    func testInvalidDesignBypassesAsRejected() {
        let specification = M1FilterSpecification(
            type: .lowShelf,
            frequencyHz: 1_000,
            gainDB: 6,
            width: .bandwidthOctaves(2),
            cornerFrequency: false
        )
        let outcome = M1BiquadFilterDesign.design(specification: specification, sampleRate: 48_000)
        XCTAssertEqual(outcome, .bypass(.coefficientsRejected))
    }

    func testDesignRejectsNonFiniteFrequencyDirectly() {
        // design() trusts the specification it is given (validation lives in
        // the node contract), so degenerate raw values reach the guards.
        let specification = M1FilterSpecification(
            type: .peaking,
            frequencyHz: .nan,
            gainDB: 3,
            width: .q(1),
            cornerFrequency: false
        )
        XCTAssertEqual(
            M1BiquadFilterDesign.design(specification: specification, sampleRate: 48_000),
            .bypass(.coefficientsRejected)
        )
    }

    func testDesignRejectsShelfSlopesOutsidePhysicalDomain() {
        let zeroSlope = M1FilterSpecification(
            type: .lowShelf,
            frequencyHz: 100,
            gainDB: 6,
            width: .slopeDBPerOctave(0),
            cornerFrequency: true
        )
        XCTAssertEqual(
            M1BiquadFilterDesign.design(specification: zeroSlope, sampleRate: 48_000),
            .bypass(.coefficientsRejected)
        )
        let infiniteSlope = M1FilterSpecification(
            type: .lowShelf,
            frequencyHz: 100,
            gainDB: 6,
            width: .slopeDBPerOctave(.infinity),
            cornerFrequency: true
        )
        XCTAssertEqual(
            M1BiquadFilterDesign.design(specification: infiniteSlope, sampleRate: 48_000),
            .bypass(.coefficientsRejected)
        )
    }

    func testDesignRejectsSlopeWidthOnNonShelfType() {
        let specification = M1FilterSpecification(
            type: .peaking,
            frequencyHz: 1_000,
            gainDB: 3,
            width: .slopeDBPerOctave(6),
            cornerFrequency: false
        )
        XCTAssertEqual(
            M1BiquadFilterDesign.design(specification: specification, sampleRate: 48_000),
            .bypass(.coefficientsRejected)
        )
    }

    func testDesignRejectsNonFiniteWidthValues() {
        let nanQ = M1FilterSpecification(
            type: .peaking,
            frequencyHz: 1_000,
            gainDB: 3,
            width: .q(.nan),
            cornerFrequency: false
        )
        XCTAssertEqual(
            M1BiquadFilterDesign.design(specification: nanQ, sampleRate: 48_000),
            .bypass(.coefficientsRejected)
        )
        let infiniteBandwidth = M1FilterSpecification(
            type: .notch,
            frequencyHz: 1_000,
            gainDB: 0,
            width: .bandwidthOctaves(.infinity),
            cornerFrequency: false
        )
        XCTAssertEqual(
            M1BiquadFilterDesign.design(specification: infiniteBandwidth, sampleRate: 48_000),
            .bypass(.coefficientsRejected)
        )
    }

    func testAllPassExtremeQLowFrequencyRemainsValid() throws {
        // Q floor 0.05 near the domain's lower frequency end must stay stable;
        // this guards the runtime's isStableBiquad mirror.
        let specification = M1FilterSpecification(
            type: .allPass,
            frequencyHz: 19_000,
            gainDB: 0,
            width: .q(0.05),
            cornerFrequency: false
        )
        let outcome = M1BiquadFilterDesign.design(specification: specification, sampleRate: 48_000)
        guard case .coefficients = outcome else {
            return XCTFail("expected coefficients, got \(outcome)")
        }
    }

    func testDesignRejectsNonPositiveFrequencyDirectly() {
        let specification = M1FilterSpecification(
            type: .notch,
            frequencyHz: -5,
            gainDB: 0,
            width: .q(30),
            cornerFrequency: false
        )
        XCTAssertEqual(
            M1BiquadFilterDesign.design(specification: specification, sampleRate: 48_000),
            .bypass(.coefficientsRejected)
        )
    }

    func testDesignRejectsVanishedDenominator() throws {
        // q = −0.5 at the quarter-band frequency drives alpha to −1, so the
        // notch denominator a0 = 1 + alpha vanishes exactly.
        let specification = M1FilterSpecification(
            type: .notch,
            frequencyHz: 12_000,
            gainDB: 0,
            width: .q(-0.5),
            cornerFrequency: false
        )
        let outcome = M1BiquadFilterDesign.design(
            specification: specification,
            sampleRate: 48_000
        )
        guard case .bypass(.coefficientsRejected) = outcome else {
            return XCTFail("expected coefficients rejection, got \(outcome)")
        }
    }

    // MARK: - Specification validation

    func testSpecificationValidationRejectsOutOfDomainValues() {
        func assertInvalid(_ specification: M1FilterSpecification) {
            XCTAssertThrowsError(
                try specification.validate(nodeID: UUID())
            )
        }
        assertInvalid(M1FilterSpecification(
            type: .peaking, frequencyHz: 0.5, gainDB: 0,
            width: .q(1), cornerFrequency: false
        ))
        assertInvalid(M1FilterSpecification(
            type: .peaking, frequencyHz: 20_001, gainDB: 0,
            width: .q(1), cornerFrequency: false
        ))
        assertInvalid(M1FilterSpecification(
            type: .peaking, frequencyHz: 1_000, gainDB: 24.1,
            width: .q(1), cornerFrequency: false
        ))
        assertInvalid(M1FilterSpecification(
            type: .peaking, frequencyHz: 1_000, gainDB: 6,
            width: .q(0.01), cornerFrequency: false
        ))
        assertInvalid(M1FilterSpecification(
            type: .peaking, frequencyHz: 1_000, gainDB: 6,
            width: .q(.nan), cornerFrequency: false
        ))
        assertInvalid(M1FilterSpecification(
            type: .peaking, frequencyHz: 1_000, gainDB: 6,
            width: .slopeDBPerOctave(6), cornerFrequency: false
        ))
        assertInvalid(M1FilterSpecification(
            type: .lowShelf, frequencyHz: 1_000, gainDB: 6,
            width: .bandwidthOctaves(2), cornerFrequency: false
        ))
        assertInvalid(M1FilterSpecification(
            type: .lowShelf, frequencyHz: 1_000, gainDB: 6,
            width: .slopeDBPerOctave(12.1), cornerFrequency: false
        ))
        assertInvalid(M1FilterSpecification(
            type: .lowPass, frequencyHz: 1_000, gainDB: 6,
            width: .q(1), cornerFrequency: false
        ))
        assertInvalid(M1FilterSpecification(
            type: .lowPass, frequencyHz: 1_000, gainDB: 0,
            width: .q(1), cornerFrequency: true
        ))
        XCTAssertNoThrow(try M1FilterSpecification(
            type: .lowPass, frequencyHz: 1_000, gainDB: 0,
            width: .q(1), cornerFrequency: false
        ).validate(nodeID: UUID()))
    }

    func testDefaultSpecificationFollowsReferenceDefaults() {
        XCTAssertEqual(
            M1FilterSpecification.defaultSpecification(type: .lowPass).width,
            .q(1.0 / 2.0.squareRoot())
        )
        XCTAssertEqual(
            M1FilterSpecification.defaultSpecification(type: .highPass).width,
            .q(1.0 / 2.0.squareRoot())
        )
        XCTAssertEqual(
            M1FilterSpecification.defaultSpecification(type: .bandPass).width,
            .q(1.0 / 2.0.squareRoot())
        )
        XCTAssertEqual(
            M1FilterSpecification.defaultSpecification(type: .notch).width,
            .q(30)
        )
        XCTAssertEqual(
            M1FilterSpecification.defaultSpecification(type: .lowShelf).width,
            .slopeDBPerOctave(10.8)
        )
        XCTAssertTrue(M1FilterSpecification.defaultSpecification(type: .lowShelf).cornerFrequency)
        XCTAssertFalse(M1FilterSpecification.defaultSpecification(type: .peaking).cornerFrequency)
        XCTAssertEqual(
            M1FilterSpecification.defaultSpecification(type: .peaking).frequencyHz,
            1_000
        )
    }

    // MARK: - Builder wiring

    func testBuildCompilesFilterNodeToBiquadStageForSelectedChannels() throws {
        let specification = M1FilterSpecification(
            type: .peaking,
            frequencyHz: 1_000,
            gainDB: 6,
            width: .q(2),
            cornerFrequency: false
        )
        let node = M1ProcessingNode.filter(specification: specification)
        let compiled = try M1ProcessingBuilder.build(nodes: [node], layout: stereoLayout())
        XCTAssertEqual(compiled.stagesByChannel.count, 2)
        for stages in compiled.stagesByChannel {
            XCTAssertEqual(stages.count, 1)
            guard case let .biquad(nodeID, bandIndex, coefficients) = stages[0] else {
                return XCTFail("expected biquad stage")
            }
            XCTAssertEqual(nodeID, node.id)
            XCTAssertEqual(bandIndex, 0)
            XCTAssertEqual(
                coefficients,
                try designCoefficients(specification, sampleRate: 48_000)
            )
        }
        XCTAssertTrue(compiled.diagnostics.filterBypasses.isEmpty)
        XCTAssertEqual(compiled.processingLatencyFrames, 0)
    }

    func testBuildSkipsDisabledFilterNodes() throws {
        let node = M1ProcessingNode.filter(isEnabled: false)
        let compiled = try M1ProcessingBuilder.build(nodes: [node], layout: stereoLayout())
        XCTAssertTrue(compiled.stagesByChannel.allSatisfy(\.isEmpty))
    }

    func testBuildReportsNyquistBypassDiagnostic() throws {
        let specification = M1FilterSpecification(
            type: .peaking,
            frequencyHz: 10_000,
            gainDB: 3,
            width: .q(1),
            cornerFrequency: false
        )
        let node = M1ProcessingNode.filter(specification: specification)
        let layout = M1OutputLayoutSnapshot(
            sampleRate: 16_000,
            maximumFrameCount: 512,
            bufferChannelCounts: [2],
            semanticPositionsByChannelIndex: [.left, .right]
        )!
        let compiled = try M1ProcessingBuilder.build(nodes: [node], layout: layout)
        XCTAssertTrue(compiled.stagesByChannel.allSatisfy(\.isEmpty))
        XCTAssertEqual(compiled.diagnostics.filterBypasses.count, 1)
        XCTAssertEqual(compiled.diagnostics.filterBypasses[0].nodeID, node.id)
        XCTAssertEqual(
            compiled.diagnostics.filterBypasses[0].reason,
            .frequencyAtOrAboveNyquist
        )
    }

    func testBuildValidatesFilterSpecificationDomain() {
        let node = M1ProcessingNode.filter(specification: .init(
            type: .peaking,
            frequencyHz: 0.5,
            gainDB: 0,
            width: .q(1),
            cornerFrequency: false
        ))
        XCTAssertThrowsError(
            try M1ProcessingBuilder.build(nodes: [node], layout: stereoLayout())
        ) { error in
            guard case M1ProcessingBuildError.invalidFilterFrequency = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testBuildFlushesPendingPreampGainBeforeBiquadStage() throws {
        let preamp = M1PreampNode(id: UUID(), isEnabled: true, gainDB: -3, channels: .all)
        let filterNode = M1ProcessingNode.filter()
        let compiled = try M1ProcessingBuilder.build(
            nodes: [preamp, filterNode],
            layout: stereoLayout()
        )
        let stages = compiled.stagesByChannel[0]
        XCTAssertEqual(stages.count, 2)
        guard case .gain = stages[0] else {
            return XCTFail("expected pending preamp gain flushed before biquad")
        }
        guard case .biquad = stages[1] else {
            return XCTFail("expected biquad stage after gain")
        }
    }

    func testInvalidSampleRateBypassesAsRejected() {
        let specification = M1FilterSpecification(
            type: .peaking,
            frequencyHz: 1_000,
            gainDB: 3,
            width: .q(1),
            cornerFrequency: false
        )
        XCTAssertEqual(
            M1BiquadFilterDesign.design(specification: specification, sampleRate: 0),
            .bypass(.coefficientsRejected)
        )
        XCTAssertEqual(
            M1BiquadFilterDesign.design(specification: specification, sampleRate: .nan),
            .bypass(.coefficientsRejected)
        )
    }

    func testCornerShelfWithDegenerateSlopeConversionKeepsFrequency() throws {
        // Q → slope conversion degenerates to |S| → ∞ at the reference gain;
        // the corner shift must become a no-op instead of producing a wild
        // frequency, and the coefficients stay valid.
        let specification = M1FilterSpecification(
            type: .lowShelf,
            frequencyHz: 100,
            gainDB: 0,
            width: .q(100),
            cornerFrequency: true
        )
        let outcome = M1BiquadFilterDesign.design(
            specification: specification,
            sampleRate: 48_000
        )
        guard case .coefficients(let coefficients) = outcome else {
            return XCTFail("expected coefficients, got \(outcome)")
        }
        XCTAssertEqual(
            Self.responseDB(coefficients, frequencyHz: 100, sampleRate: 48_000),
            0,
            accuracy: 0.01
        )
    }

    func testShelfCornerConversionWithPositiveGainKeepsStability() throws {
        let specification = M1FilterSpecification(
            type: .lowShelf,
            frequencyHz: 80,
            gainDB: 12,
            width: .q(0.5),
            cornerFrequency: true
        )
        let outcome = M1BiquadFilterDesign.design(
            specification: specification,
            sampleRate: 48_000
        )
        guard case .coefficients(let coefficients) = outcome else {
            return XCTFail("expected coefficients, got \(outcome)")
        }
        // Center shifted to 80 × 10^(12/80/S); half-gain lands there.
        let s = 1.0 / ((1.0 / (0.5 * 0.5) - 2.0) / (amplitudeOf(12) + 1.0 / amplitudeOf(12)) + 1.0)
        let center = 80.0 * pow(10.0, 12.0 / 80.0 / s)
        XCTAssertEqual(
            Self.responseDB(coefficients, frequencyHz: center, sampleRate: 48_000),
            6,
            accuracy: 0.05
        )
    }

    private func amplitudeOf(_ gainDB: Double) -> Double {
        pow(10.0, gainDB / 40.0)
    }

    func testFilterSpecificationTransformHelpersPreserveInvariants() {
        let peaking = M1FilterSpecification(
            type: .peaking,
            frequencyHz: 1_000,
            gainDB: 6,
            width: .q(2),
            cornerFrequency: false
        )
        XCTAssertEqual(peaking.widthValue, 2)

        // Switching to a shelf adopts corner semantics and keeps a Q width
        // (shelves accept Q); only width kinds the new type cannot express
        // are reset to that type's default.
        let shelf = peaking.withType(.lowShelf)
        XCTAssertEqual(shelf.type, .lowShelf)
        XCTAssertTrue(shelf.cornerFrequency)
        XCTAssertEqual(shelf.width, .q(2))

        // Switching a shelf with Q to a non-shelf keeps Q and drops the
        // corner flag; non-gain types zero the gain.
        let shelfWithQ = M1FilterSpecification(
            type: .lowShelf,
            frequencyHz: 100,
            gainDB: 6,
            width: .q(0.7),
            cornerFrequency: true
        )
        let lowPass = shelfWithQ.withType(.lowPass)
        XCTAssertFalse(lowPass.cornerFrequency)
        XCTAssertEqual(lowPass.width, .q(0.7))
        XCTAssertEqual(lowPass.gainDB, 0)

        // Slope widths only exist for shelves: leaving the shelf resets to
        // the peaking default Q.
        let slopeShelf = M1FilterSpecification(
            type: .lowShelf,
            frequencyHz: 100,
            gainDB: 6,
            width: .slopeDBPerOctave(6),
            cornerFrequency: true
        )
        let peakFromShelf = slopeShelf.withType(.peaking)
        XCTAssertFalse(peakFromShelf.cornerFrequency)
        XCTAssertEqual(peakFromShelf.width, .q(M1FilterContract.defaultQ))
        XCTAssertEqual(peakFromShelf.gainDB, 6)

        // Bandwidth widths only exist for non-shelves: entering the shelf
        // resets to the shelf default slope.
        let widePeak = M1FilterSpecification(
            type: .peaking,
            frequencyHz: 1_000,
            gainDB: 0,
            width: .bandwidthOctaves(2),
            cornerFrequency: false
        )
        XCTAssertEqual(widePeak.widthValue, 2)
        let shelfFromWidePeak = widePeak.withType(.highShelf)
        XCTAssertTrue(shelfFromWidePeak.cornerFrequency)
        XCTAssertEqual(
            shelfFromWidePeak.width,
            .slopeDBPerOctave(M1FilterContract.defaultShelfSlopeDBPerOctave)
        )

        // Switching between shelf types keeps the corner setting and slope.
        let highShelf = slopeShelf.withType(.highShelf)
        XCTAssertEqual(highShelf.type, .highShelf)
        XCTAssertTrue(highShelf.cornerFrequency)
        XCTAssertEqual(highShelf.width, .slopeDBPerOctave(6))

        XCTAssertEqual(peaking.withFrequencyHz(500).frequencyHz, 500)
        XCTAssertEqual(peaking.withGainDB(-3).gainDB, -3)
        XCTAssertEqual(peaking.withWidth(.bandwidthOctaves(1)).width, .bandwidthOctaves(1))
        XCTAssertEqual(peaking.withWidthValue(8).width, .q(8))
        let shelfSlope = M1FilterSpecification(
            type: .highShelf,
            frequencyHz: 1_000,
            gainDB: 3,
            width: .slopeDBPerOctave(6),
            cornerFrequency: true
        )
        XCTAssertEqual(shelfSlope.withWidthValue(9).width, .slopeDBPerOctave(9))
        let bandwidthSpec = M1FilterSpecification(
            type: .peaking,
            frequencyHz: 1_000,
            gainDB: 3,
            width: .bandwidthOctaves(2),
            cornerFrequency: false
        )
        XCTAssertEqual(bandwidthSpec.withWidthValue(3).width, .bandwidthOctaves(3))
        XCTAssertFalse(shelfSlope.withCornerFrequency(false).cornerFrequency)
        XCTAssertTrue(shelfSlope.withCornerFrequency(false).withCornerFrequency(true).cornerFrequency)
    }

    // MARK: - Helpers

    private func designCoefficients(
        _ specification: M1FilterSpecification,
        sampleRate: Double
    ) throws -> M1BiquadCoefficients {
        switch M1BiquadFilterDesign.design(
            specification: specification,
            sampleRate: sampleRate
        ) {
        case .coefficients(let coefficients):
            return coefficients
        case .bypass(let reason):
            throw XCTFailure("unexpected bypass: \(reason)")
        }
    }

    private func stereoLayout() -> M1OutputLayoutSnapshot {
        M1OutputLayoutSnapshot(
            sampleRate: 48_000,
            maximumFrameCount: 512,
            bufferChannelCounts: [2],
            semanticPositionsByChannelIndex: [.left, .right]
        )!
    }

    /// Magnitude response of the normalized biquad `H(z)` at a frequency.
    private static func responseDB(
        _ coefficients: M1BiquadCoefficients,
        frequencyHz: Double,
        sampleRate: Double
    ) -> Double {
        let omega = 2 * Double.pi * frequencyHz / sampleRate
        let z1Real = cos(omega)
        let z1Imaginary = -sin(omega)
        let z2Real = cos(2 * omega)
        let z2Imaginary = -sin(2 * omega)
        let numeratorReal = coefficients.b0
            + coefficients.b1 * z1Real
            + coefficients.b2 * z2Real
        let numeratorImaginary = coefficients.b1 * z1Imaginary
            + coefficients.b2 * z2Imaginary
        let denominatorReal = 1
            + coefficients.a1 * z1Real
            + coefficients.a2 * z2Real
        let denominatorImaginary = coefficients.a1 * z1Imaginary
            + coefficients.a2 * z2Imaginary
        let magnitude = hypot(numeratorReal, numeratorImaginary)
            / hypot(denominatorReal, denominatorImaginary)
        return 20 * log10(magnitude)
    }
}

private struct XCTFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
