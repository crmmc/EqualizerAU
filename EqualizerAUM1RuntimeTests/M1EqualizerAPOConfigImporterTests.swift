import Foundation
import XCTest

final class M1EqualizerAPOConfigImporterTests: XCTestCase {
    private let mainURL = URL(fileURLWithPath: "/fake/config/config.txt")

    /// Fake filesystem: absolute path → file content.
    private func makePlan(
        _ content: String,
        files: [String: String] = [:]
    ) throws -> M1APOConfigImportPlan {
        let filesystem = files.merging([mainURL.path: content]) { _, new in new }
        return try M1EqualizerAPOConfigImporter.makePlan(mainFile: mainURL) { url in
            guard let text = filesystem[url.path] else {
                throw CocoaError(.fileNoSuchFile)
            }
            return text
        }
    }

    // MARK: - Command mapping

    func testMapsSixCommandTypesInSourceOrder() throws {
        let plan = try makePlan("""
        # migration config
        Device: Speakers
        Preamp: -6 dB
        Filter  1: ON  PK Fc 50 Hz Gain -3.0 dB Q 10.00
        GraphicEQ: 100 2; 200 -1
        Delay: 50.5 ms
        Channel: L RL
        Filter  2: ON  HP Fc 30 Hz
        Convolution: ir/correction.wav
        """)
        XCTAssertEqual(
            plan.nodes.map(\.kind),
            [.preamp, .filter, .graphicEQ, .delay, .channels, .filter, .convolution]
        )
        XCTAssertEqual(plan.nodes[0].gainDB, -6)
        XCTAssertEqual(plan.nodes[1].filterSpecification?.frequencyHz, 50)
        XCTAssertEqual(plan.nodes[3].delaySpecification, M1DelaySpecification(value: 50.5, unit: .milliseconds))
        guard case .identifiers(let labels) = plan.nodes[4].channels else {
            return XCTFail("expected identifier selection")
        }
        XCTAssertEqual(labels.map(\.rawValue), ["L", "RL"])
        XCTAssertEqual(
            plan.nodes[6].convolutionIR?.sourcePath,
            "/fake/config/ir/correction.wav"
        )
        // The implicit leading `all` scope produced no Channels node, and the
        // single Device line is a per-item issue.
        XCTAssertNotEqual(plan.nodes.first?.kind, .channels)
        XCTAssertFalse(plan.hasMultipleDeviceSections)
        XCTAssertEqual(plan.issues.map(\.category), [.deviceGate])
    }

    func testCommandMatchingIsCaseInsensitiveAndIgnoresSlotNoise() throws {
        let plan = try makePlan("""
        preaMP: -3 dB
        Filter 7: OFF None
        Filter 8: ON None
        Filter 9:
        """)
        XCTAssertEqual(plan.nodes.count, 1)
        XCTAssertEqual(plan.nodes[0].gainDB, -3)
        // REW slot noise is skipped silently, not reported.
        XCTAssertTrue(plan.issues.isEmpty)
    }

    func testDisabledFilterImportsAsDisabledNode() throws {
        let plan = try makePlan("Filter 3: OFF PK Fc 120 Hz Gain 2.5 dB Q 1.00")
        XCTAssertEqual(plan.nodes.count, 1)
        XCTAssertEqual(plan.nodes[0].kind, .filter)
        XCTAssertFalse(plan.nodes[0].isEnabled)
        XCTAssertEqual(plan.disabledFilterCount, 1)
        XCTAssertEqual(plan.nodeCountByKind[.filter], 1)
    }

    func testREWExportShapeWithCommaDecimals() throws {
        let plan = try makePlan("""
        Filter Settings file

        Room EQ V5,01
        Dated: 29.02.2012 20:04:50

        Notes:Simple bass boost

        Equaliser: Generic
        No measurement
        Filter  1: ON  PK       Fc    20,0 Hz  Gain   4,0 dB  Q  1,00
        Filter  2: ON  PK       Fc    45,0 Hz  Gain   2,0 dB  Q  1,00
        Filter  3: OFF None
        """)
        let filters = plan.nodes.filter { $0.kind == .filter }
        XCTAssertEqual(filters.count, 2)
        XCTAssertEqual(filters[0].filterSpecification?.frequencyHz, 20)
        XCTAssertEqual(filters[0].filterSpecification?.gainDB, 4)
        XCTAssertEqual(filters[1].filterSpecification?.frequencyHz, 45)
    }

    func testSelectiveDelayFileReportsCopyButImportsFiltersAndDelay() throws {
        let plan = try makePlan("""
        Copy: L2=L R2=R
        Channel: L2 R2
        Filter: ON HP Fc 200 Hz
        Filter: ON LP Fc 2000 Hz
        Delay: 500 ms
        Copy: L=0.5*L+0.5*L2 R=0.5*R+0.5*R2
        """)
        XCTAssertEqual(
            plan.nodes.map(\.kind),
            [.channels, .filter, .filter, .delay]
        )
        XCTAssertEqual(plan.issues.count, 2)
        XCTAssertTrue(plan.issues.allSatisfy { $0.category == .unsupportedCommand })
        XCTAssertEqual(plan.issues.map(\.command), ["Copy", "Copy"])
    }

    // MARK: - Skipped command reporting

    func testSkippedCommandsAreReportedPerCategoryWithLineNumbers() throws {
        let plan = try makePlan("""
        Device: Speakers
        Stage: pre-mix
        If: sampleRate == 44100
            Filter: ON PK Fc 100 Hz Gain 1 dB Q 2
            If: inputChannelCount == 2
                Filter: ON HP Fc 30 Hz
            EndIf:
        EndIf:
        Eval: a=0; b=pi
        Filter: ON PK Fc 1000 Hz Gain `20*log10(0.5)` dB Q 10.0
        VSTPlugin: reverb.dll
        LoudnessCorrection: 80
        Copy: L=L+0.5*R
        Filter: ON IIR Order 2 Coefficients 0.03 0.07 0.03 1.27 -1.84 0.72
        """)
        XCTAssertEqual(
            plan.issues.map(\.category),
            [
                .deviceGate, .deviceGate,
                .conditionalBlock(lineCount: 6),
                .expression, .expression,
                .unsupportedCommand, .unsupportedCommand, .unsupportedCommand,
                .unsupportedCommand,
            ]
        )
        XCTAssertEqual(
            plan.issues.map(\.command),
            ["Device", "Stage", "If", "Eval", "Filter", "VSTPlugin", "LoudnessCorrection", "Copy", "Filter"]
        )
        XCTAssertEqual(plan.issues[0].lineNumber, 1)
        XCTAssertEqual(plan.issues[2].lineNumber, 3)
        XCTAssertEqual(plan.issues[2].fileIndex, 0)
        XCTAssertEqual(plan.nodes.count, 0)
        XCTAssertFalse(plan.hasMultipleDeviceSections)
    }

    func testMultipleDeviceSectionsRaisePlanWarning() throws {
        let plan = try makePlan("""
        Device: Speakers
        Preamp: -3 dB
        Device: Headphones
        Preamp: -6 dB
        """)
        XCTAssertTrue(plan.hasMultipleDeviceSections)
        XCTAssertEqual(plan.nodes.count, 2)
        XCTAssertEqual(plan.issues.filter { $0.category == .deviceGate }.count, 2)
    }

    func testUnterminatedIfBlockConsumesRemainderOfFile() throws {
        let plan = try makePlan("""
        If: sampleRate == 44100
            Filter: ON PK Fc 100 Hz Gain 1 dB Q 2
        Preamp: -3 dB
        """)
        XCTAssertEqual(plan.issues.map(\.category), [.conditionalBlock(lineCount: 3)])
        XCTAssertEqual(plan.nodes.count, 0)
    }

    // MARK: - Include

    func testIncludeChainInlinesNestedFilesInOrder() throws {
        let plan = try makePlan(
            """
            Preamp: -6 dB
            Channel: L
            Include: demo.txt
            """,
            files: [
                "/fake/config/demo.txt": """
                Filter: ON LS Fc 300 Hz Gain 5.0 dB
                Include: sub/inner.txt
                """,
                "/fake/config/sub/inner.txt": "Delay: 10 ms\n",
            ]
        )
        XCTAssertEqual(
            plan.nodes.map(\.kind),
            [.preamp, .channels, .filter, .delay]
        )
        XCTAssertEqual(plan.fileNames, ["config.txt", "demo.txt", "inner.txt"])
        XCTAssertTrue(plan.issues.isEmpty)
    }

    func testIncludeCycleStopsAndReportsAgainstIncluder() throws {
        let plan = try makePlan(
            """
            Include: b.txt
            Preamp: -3 dB
            """,
            files: [
                "/fake/config/b.txt": """
                Filter: ON HP Fc 30 Hz
                Include: config.txt
                """,
            ]
        )
        XCTAssertEqual(plan.nodes.map(\.kind), [.filter, .preamp])
        XCTAssertEqual(plan.issues.count, 1)
        XCTAssertEqual(plan.issues[0].category, .includeFailure)
        XCTAssertEqual(plan.issues[0].fileIndex, 1)
        XCTAssertEqual(plan.issues[0].lineNumber, 2)
    }

    func testIncludeBeyondDepthBudgetFailsWithoutLoadingDeepestFile() throws {
        var files: [String: String] = [:]
        for depth in 0...8 {
            files["/fake/config/f\(depth).txt"] = "Include: f\(depth + 1).txt\n"
        }
        files["/fake/config/f9.txt"] = "Filter: ON NO Fc 50 Hz\n"
        let plan = try makePlan("Include: f0.txt\n", files: files)
        XCTAssertTrue(plan.nodes.isEmpty)
        XCTAssertEqual(plan.issues.count, 1)
        XCTAssertEqual(plan.issues[0].category, .includeFailure)
        XCTAssertEqual(plan.fileNames.count, 9)
    }

    func testUnreadableIncludeIsReportedAndParsingContinues() throws {
        let plan = try makePlan(
            """
            Include: missing.txt
            Preamp: -3 dB
            """
        )
        XCTAssertEqual(plan.nodes.map(\.kind), [.preamp])
        XCTAssertEqual(plan.issues.map(\.category), [.includeFailure])
        // The failure is attributed to the includer's location.
        XCTAssertEqual(plan.issues[0].fileIndex, 0)
        XCTAssertEqual(plan.issues[0].lineNumber, 1)
    }

    // MARK: - Convolution paths

    func testConvolutionPathVariants() throws {
        let plan = try makePlan("""
        Convolution: church.wav
        Convolution: C:\\Users\\me\\ir.flac
        Convolution: /absolute/ir.wav
        Convolution: hall.ogg
        """)
        let nodes = plan.nodes.compactMap(\.convolutionIR)
        XCTAssertEqual(nodes.map(\.sourcePath), [
            "/fake/config/church.wav",
            "C:\\Users\\me\\ir.flac",
            "/absolute/ir.wav",
            "/fake/config/hall.ogg",
        ])
        XCTAssertEqual(
            plan.issues.map(\.category),
            [.convolutionPath, .convolutionFormat, .convolutionFormat]
        )
    }

    // MARK: - Domain failures

    func testFilterDomainViolationIsAnInvalidLineIssue() throws {
        let plan = try makePlan("Filter: ON PK Fc 0.5 Hz Gain 1 dB Q 1")
        XCTAssertTrue(plan.nodes.isEmpty)
        XCTAssertEqual(plan.issues.map(\.category), [.invalidLine])
    }

    func testPreampClampingAndInvalidValues() throws {
        let plan = try makePlan("""
        Preamp: -150 dB
        Preamp: 120 dB
        Preamp: abc dB
        Preamp: -6
        """)
        XCTAssertEqual(plan.nodes.count, 2)
        XCTAssertEqual(plan.nodes[0].gainDB, -100)
        XCTAssertEqual(plan.nodes[1].gainDB, 100)
        XCTAssertEqual(plan.issues.map(\.category), [.invalidLine, .invalidLine])
    }

    func testDelayDomainViolationsAreInvalidLinesButBudgetStaysUnchecked() throws {
        let plan = try makePlan("""
        Delay: 0 ms
        Delay: 5 samples
        Delay: 2000 ms
        Delay: 10 sec
        """)
        XCTAssertEqual(plan.nodes.count, 2)
        XCTAssertEqual(
            plan.nodes[0].delaySpecification,
            M1DelaySpecification(value: 5, unit: .samples)
        )
        XCTAssertEqual(
            plan.nodes[1].delaySpecification,
            M1DelaySpecification(value: 2000, unit: .milliseconds)
        )
        XCTAssertEqual(plan.issues.map(\.category), [.invalidLine, .invalidLine])
    }

    func testChannelAllAndNumericSelections() throws {
        let plan = try makePlan("""
        Channel: all
        Channel: 1 2 C
        Channel:
        Channel: ALL
        """)
        XCTAssertEqual(plan.nodes.count, 3)
        XCTAssertEqual(plan.nodes[0].channels, .all)
        guard case .identifiers(let labels) = plan.nodes[1].channels else {
            return XCTFail("expected identifier selection")
        }
        XCTAssertEqual(labels.map(\.rawValue), ["1", "2", "C"])
        XCTAssertEqual(plan.issues.map(\.category), [.invalidLine])
        XCTAssertEqual(plan.nodes.first?.kind, .channels)
    }

    // MARK: - Hard failures

    func testGraphicEQPointLimitAbortsWholeImport() throws {
        // Frequencies stay inside the 20...20000 Hz domain so the codec's
        // unique-point budget check is what fires.
        var line = "GraphicEQ: "
        for index in 0..<(M1GraphicEQContract.maximumPointCount + 1) {
            let frequency = 20 + index
            line += index == 0 ? "\(frequency) 0" : "; \(frequency) 0"
        }
        XCTAssertThrowsError(try makePlan(line + "\n")) { error in
            XCTAssertEqual(
                error as? M1EqualizerAPOConfigImporterError,
                .graphicEQPointLimitExceeded(
                    count: M1GraphicEQContract.maximumPointCount + 1,
                    maximum: M1GraphicEQContract.maximumPointCount
                )
            )
        }
    }

    func testFileWithoutRecognizedCommandsThrows() {
        XCTAssertThrowsError(try makePlan("just some text\nmore text\n")) { error in
            XCTAssertEqual(
                error as? M1EqualizerAPOConfigImporterError,
                .noRecognizedCommands
            )
        }
    }

    func testUnreadableMainFileThrows() {
        XCTAssertThrowsError(
            try M1EqualizerAPOConfigImporter.makePlan(mainFile: mainURL) { _ in
                throw CocoaError(.fileNoSuchFile)
            }
        ) { error in
            XCTAssertEqual(
                error as? M1EqualizerAPOConfigImporterError,
                .fileUnreadable(path: mainURL.path)
            )
        }
    }

    func testTotalSizeLimitExceededThrows() {
        let padding = String(repeating: "# padding line\n", count: 320_000)
        XCTAssertThrowsError(try makePlan(padding)) { error in
            guard case .totalSizeLimitExceeded = error as! M1EqualizerAPOConfigImporterError else {
                return XCTFail("expected totalSizeLimitExceeded")
            }
        }
    }

    func testDiskReaderReadsUTF8TextAndThrowsForMissingFiles() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m14-\(UUID().uuidString).txt")
        try "Preamp: -3 dB\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = M1DiskConfigFileReader()
        XCTAssertEqual(try reader.readText(at: url), "Preamp: -3 dB\n")
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("m14-missing-\(UUID().uuidString).txt")
        XCTAssertThrowsError(try reader.readText(at: missing))
    }

    func testDiskReaderFallsBackToLatin1Encoding() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m14-ansi-\(UUID().uuidString).txt")
        let content = "Preamp: -3 dB\n# Kommentar mit ä\n"
        try content.data(using: .isoLatin1)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try M1DiskConfigFileReader().readText(at: url), content)
    }

    func testIncludeRestoresOuterAllScopeAfterScopedInnerFile() throws {
        let plan = try makePlan(
            """
            Preamp: -6 dB
            Include: scoped.txt
            Preamp: -3 dB
            """,
            files: [
                "/fake/config/scoped.txt": """
                Filter: ON HP Fc 30 Hz
                Channel: R
                """,
            ]
        )
        // A restore node returns the chain to the outer implicit-all scope.
        XCTAssertEqual(
            plan.nodes.map(\.kind),
            [.preamp, .filter, .channels, .channels, .preamp]
        )
        XCTAssertEqual(plan.nodes[2].channels, .identifiers([M1ChannelIdentifier("R")!]))
        XCTAssertEqual(plan.nodes[3].channels, .all)
    }

    func testIncludeRestoresOuterScopedSelectionAfterInnerChange() throws {
        let plan = try makePlan(
            """
            Channel: L
            Include: scoped.txt
            Delay: 10 ms
            """,
            files: [
                "/fake/config/scoped.txt": """
                Channel: R
                Filter: ON HP Fc 30 Hz
                """,
            ]
        )
        XCTAssertEqual(
            plan.nodes.map(\.kind),
            [.channels, .channels, .filter, .channels, .delay]
        )
        XCTAssertEqual(plan.nodes[0].channels, .identifiers([M1ChannelIdentifier("L")!]))
        XCTAssertEqual(plan.nodes[3].channels, .identifiers([M1ChannelIdentifier("L")!]))
    }

    func testFilterLineLimitAbortsWholeImport() {
        let maximum = M1EqualizerAPOTextCodec.maximumFilterLines
        var lines = ""
        for index in 1...(maximum + 1) {
            lines += "Filter \(index): ON PK Fc \(100 + index) Hz Gain 1 dB Q 1\n"
        }
        XCTAssertThrowsError(try makePlan(lines)) { error in
            XCTAssertEqual(
                error as? M1EqualizerAPOConfigImporterError,
                .filterLineLimitExceeded(count: maximum + 1, maximum: maximum)
            )
        }
    }

    func testReaderSizeErrorIsNotMaskedAsUnreadable() {
        XCTAssertThrowsError(
            try M1EqualizerAPOConfigImporter.makePlan(mainFile: mainURL) { _ in
                throw M1EqualizerAPOConfigImporterError.totalSizeLimitExceeded(
                    bytes: 5_000_000,
                    maximum: M1EqualizerAPOConfigImporter.maximumTotalBytes
                )
            }
        ) { error in
            guard case .totalSizeLimitExceeded = error as! M1EqualizerAPOConfigImporterError else {
                return XCTFail("expected totalSizeLimitExceeded to propagate")
            }
        }
    }

    func testOrphanConditionalKeywordsAreReported() throws {
        let plan = try makePlan("""
        EndIf:
        Preamp: -3 dB
        """)
        XCTAssertEqual(plan.nodes.map(\.kind), [.preamp])
        XCTAssertEqual(plan.issues.map(\.category), [.invalidLine])
        XCTAssertEqual(plan.issues.map(\.command), ["EndIf"])
    }
}
