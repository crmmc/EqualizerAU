import Foundation
import XCTest

final class M1EqualizerAPOTextCodecTests: XCTestCase {
    func testParsesCanonicalFilterLinesInOrder() throws {
        let text = """
        Filter: ON PK Fc 50 Hz Gain -3.0 dB Q 10.00
        GraphicEQ: 100 2; 200 -1
        Filter 2: ON PEQ Fc 100 Hz Gain 1.0 dB BW Oct 0.167
        Filter: ON LS Fc 300 Hz Gain 5.0 dB
        Filter: ON HP Fc 30 Hz
        Filter: ON NO Fc 50 Hz
        Filter: ON AP Fc 900 Hz Q 0.707
        """
        let paste = try M1EqualizerAPOTextCodec.parse(text)
        XCTAssertEqual(paste.nodes.count, 7)
        XCTAssertEqual(paste.report.graphicEQLineCount, 1)
        XCTAssertEqual(paste.report.filterLineCount, 6)
        XCTAssertEqual(paste.report.ignoredLineCount, 0)

        XCTAssertEqual(paste.nodes[0].kind, .filter)
        guard let first = paste.nodes[0].filterSpecification else {
            return XCTFail("expected filter specification")
        }
        XCTAssertEqual(first.type, .peaking)
        XCTAssertEqual(first.frequencyHz, 50)
        XCTAssertEqual(first.gainDB, -3)
        XCTAssertEqual(first.width, .q(10))
        XCTAssertFalse(first.cornerFrequency)

        XCTAssertEqual(paste.nodes[1].kind, .graphicEQ)

        guard let second = paste.nodes[2].filterSpecification else {
            return XCTFail("expected filter specification")
        }
        XCTAssertEqual(second.type, .peaking)
        XCTAssertEqual(second.width, .bandwidthOctaves(0.167))

        guard let shelf = paste.nodes[3].filterSpecification else {
            return XCTFail("expected filter specification")
        }
        XCTAssertEqual(shelf.type, .lowShelf)
        XCTAssertEqual(shelf.gainDB, 5)
        XCTAssertEqual(shelf.width, .slopeDBPerOctave(10.8))
        XCTAssertTrue(shelf.cornerFrequency)

        guard let highPass = paste.nodes[4].filterSpecification else {
            return XCTFail("expected filter specification")
        }
        XCTAssertEqual(highPass.type, .highPass)
        XCTAssertEqual(highPass.gainDB, 0)
        XCTAssertEqual(highPass.width, .q(1.0 / 2.0.squareRoot()))

        guard let notch = paste.nodes[5].filterSpecification else {
            return XCTFail("expected filter specification")
        }
        XCTAssertEqual(notch.type, .notch)
        XCTAssertEqual(notch.width, .q(30))
    }

    func testNormalizesTypeAliasesAndShelfVariants() throws {
        let text = """
        Filter: ON Modal Fc 100 Hz Gain 3.0 dB Q 5.41
        Filter: ON LPQ Fc 10000 Hz Q 0.400
        Filter: ON BP Fc 1000 Hz
        Filter: ON HPQ Fc 20.0 Hz Q 0.500
        Filter: ON LSC 10.8 dB Fc 300 Hz Gain 5.0 dB
        Filter: ON LSC Fc 300 Hz Gain 5.0 dB Q 0.6473
        Filter: ON HS 6dB Fc 12000 Hz Gain 10.0 dB
        Filter: ON HSC Fc 100 Hz Gain -6.0 dB Q 0.4272
        """
        let specifications = try M1EqualizerAPOTextCodec.parseFilterLines(text)
        XCTAssertEqual(specifications.count, 8)

        XCTAssertEqual(specifications[0].type, .peaking)
        XCTAssertEqual(specifications[0].width, .q(5.41))

        XCTAssertEqual(specifications[1].type, .lowPass)
        XCTAssertEqual(specifications[1].width, .q(0.4))

        XCTAssertEqual(specifications[2].type, .bandPass)
        XCTAssertEqual(specifications[2].width, .q(1.0 / 2.0.squareRoot()))

        XCTAssertEqual(specifications[3].type, .highPass)
        XCTAssertEqual(specifications[3].width, .q(0.5))

        XCTAssertEqual(specifications[4].type, .lowShelf)
        XCTAssertFalse(specifications[4].cornerFrequency)
        XCTAssertEqual(specifications[4].width, .slopeDBPerOctave(10.8))

        XCTAssertEqual(specifications[5].type, .lowShelf)
        XCTAssertFalse(specifications[5].cornerFrequency)
        XCTAssertEqual(specifications[5].width, .q(0.6473))

        XCTAssertEqual(specifications[6].type, .highShelf)
        XCTAssertTrue(specifications[6].cornerFrequency)
        XCTAssertEqual(specifications[6].width, .slopeDBPerOctave(6))

        XCTAssertEqual(specifications[7].type, .highShelf)
        XCTAssertFalse(specifications[7].cornerFrequency)
        XCTAssertEqual(specifications[7].width, .q(0.4272))
    }

    func testClampsGainAndAppliesDomainBoundaries() throws {
        let text = "Filter: ON PK Fc 100 Hz Gain 99 dB Q 1"
        let specifications = try M1EqualizerAPOTextCodec.parseFilterLines(text)
        XCTAssertEqual(specifications[0].gainDB, 24)
    }

    func testDropsInvalidLinesWithVisibleCounts() throws {
        let text = """
        Filter: ON XX Fc 100 Hz Gain 1 dB Q 1
        Filter: ON PK Fc 100 Hz Gain 1 dB
        Filter: ON AP Fc 900 Hz
        Filter: ON PK Fc 0.5 Hz Gain 1 dB Q 1
        Filter: ON PK Fc 100000 Hz Gain 1 dB Q 1
        Filter: ON PK Gain 1 dB Q 1
        Filter: nonsense parameters
        Filter: ON None Fc 100 Hz
        """
        let paste = try M1EqualizerAPOTextCodec.parse(text)
        XCTAssertTrue(paste.nodes.isEmpty)
        XCTAssertEqual(paste.report.filterLineCount, 0)
        XCTAssertEqual(paste.report.ignoredLineCount, 8)
        XCTAssertTrue(paste.report.hasIgnoredContent)
    }

    func testCountsRedundantParametersPerReferenceSemantics() throws {
        let text = """
        Filter: ON LP Fc 8000 Hz Gain 3 dB
        Filter: ON LS Fc 300 Hz Gain 5.0 dB BW Oct 1.0 Q 0.7
        """
        let paste = try M1EqualizerAPOTextCodec.parse(text)
        XCTAssertEqual(paste.nodes.count, 2)
        XCTAssertEqual(paste.report.ignoredLineCount, 0)
        // Gain on a low-pass and BW on a shelf are ignored informationally.
        XCTAssertEqual(paste.report.ignoredParameterCount, 2)
        XCTAssertTrue(paste.report.hasIgnoredContent)

        guard let lowPass = paste.nodes[0].filterSpecification else {
            return XCTFail("expected filter specification")
        }
        XCTAssertEqual(lowPass.gainDB, 0)
        XCTAssertEqual(lowPass.width, .q(1.0 / 2.0.squareRoot()))

        guard let shelf = paste.nodes[1].filterSpecification else {
            return XCTFail("expected filter specification")
        }
        XCTAssertEqual(shelf.width, .q(0.7))
    }

    func testTreatsDotAsDecimalOnlyNotThousandsSeparator() throws {
        let text = "Filter: ON PK Fc 1.000 Hz Gain 2 dB Q 1"
        let specifications = try M1EqualizerAPOTextCodec.parseFilterLines(text)
        XCTAssertEqual(specifications[0].frequencyHz, 1.0)
    }

    func testGarbageNumbersFallBackToReferenceDefaultsOrDropLines() throws {
        let text = """
        Filter: ON LS zz dB Fc 300 Hz Gain 5.0 dB
        Filter: ON PK Fc 100 Hz Gain zz dB Q 1
        Filter: ON PK Fc 100 Hz Gain 1 dB Q zz
        Filter: ON PK Fc 100 Hz Gain 1 dB Q 2 BW Oct zz
        Filter: ON PK Fc zz Hz Gain 1 dB Q 1
        """
        let paste = try M1EqualizerAPOTextCodec.parse(text)
        XCTAssertEqual(paste.nodes.count, 3)
        XCTAssertEqual(paste.report.ignoredLineCount, 2)

        // A shelf slope token that is not a number is skipped; the shelf
        // falls back to the reference default slope.
        guard let shelf = paste.nodes[0].filterSpecification else {
            return XCTFail("expected shelf node")
        }
        XCTAssertEqual(shelf.width, .slopeDBPerOctave(M1FilterContract.defaultShelfSlopeDBPerOctave))

        // Garbage gain parses as absent → 0 for the peaking line.
        guard let peaking = paste.nodes[1].filterSpecification else {
            return XCTFail("expected peaking node")
        }
        XCTAssertEqual(peaking.gainDB, 0)

        // Garbage Q falls through to the peaking requirement: that line is
        // dropped; garbage bandwidth falls back to the valid Q.
        guard let bandwidthPeaking = paste.nodes[2].filterSpecification else {
            return XCTFail("expected bandwidth peaking node")
        }
        XCTAssertEqual(bandwidthPeaking.width, .q(2))
    }

    func testConvertsCommaDecimalsWhenNoDotPresent() throws {
        let text = "Filter: ON PK Fc 100,5 Hz Gain 2 dB Q 0,5"
        let specifications = try M1EqualizerAPOTextCodec.parseFilterLines(text)
        XCTAssertEqual(specifications[0].frequencyHz, 100.5)
        XCTAssertEqual(specifications[0].width, .q(0.5))
    }

    func testFilterLineLimitAbortsEntirePaste() {
        let lines = (0...(M1EqualizerAPOTextCodec.maximumFilterLines + 1)).map { index in
            "Filter: ON PK Fc \(100 + index) Hz Gain 1 dB Q 1"
        }
        XCTAssertThrowsError(try M1EqualizerAPOTextCodec.parse(lines.joined(separator: "\n"))) {
            error in
            guard case M1EqualizerAPOTextCodecError.filterLineLimitExceeded(
                let count,
                let maximum
            ) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(count, M1EqualizerAPOTextCodec.maximumFilterLines + 1)
            XCTAssertEqual(maximum, M1EqualizerAPOTextCodec.maximumFilterLines)
        }
    }

    func testPlainTextWithoutCommandsYieldsEmptyPaste() throws {
        let paste = try M1EqualizerAPOTextCodec.parse("just some text\nno commands here")
        XCTAssertTrue(paste.nodes.isEmpty)
        XCTAssertEqual(paste.report.ignoredLineCount, 0)
        XCTAssertFalse(paste.report.hasIgnoredContent)
    }
}

