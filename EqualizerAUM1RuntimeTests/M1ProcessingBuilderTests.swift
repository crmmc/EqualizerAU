import Foundation
import XCTest

final class M1ProcessingBuilderTests: XCTestCase {
    func testSwiftBridgeCreatesPreparedV3FromCompiledGraphicEQConvolution() throws {
        var points = M1GraphicEQContract.legacyFlatPoints
        points[8].gainDB = 6
        let equalizer = M1ProcessingNode.graphicEQ(id: UUID(), points: points)
        let compiled = try M1ProcessingBuilder.build(
            nodes: [equalizer],
            layout: stereoLayout()
        )

        guard case let .convolution(_, taps) = compiled.stagesByChannel[0][0] else {
            return XCTFail("expected Graphic EQ convolution stage")
        }
        XCTAssertEqual(taps.count, M1ProcessingBuilder.graphicEQTapCount(forSampleRate: 48_000))

        let prepared = try M1RuntimePreparedStateFactory.create(
            stagesByChannel: compiled.stagesByChannel
        )

        XCTAssertNotNil(prepared)
        EAUM1PreparedStateDestroy(prepared)
    }

    func testEmptyChainBuildsTransparentTargetsWithoutDiagnostics() throws {
        let result = try M1ProcessingBuilder.build(nodes: [], layout: stereoLayout())

        XCTAssertEqual(result.linearGainsByChannel, [1, 1])
        XCTAssertEqual(
            result.diagnostics,
            M1ProcessingBuildDiagnostics(
                unresolvedChannels: [],
                clippingRiskChannels: [],
                gainBoundaries: []
            )
        )
    }

    func testSelectedChannelsCompileAndUnresolvedIdentifiersRemainDiagnosticOnly() throws {
        let nodeID = UUID()
        let left = try XCTUnwrap(M1ChannelIdentifier("L"))
        let missing = try XCTUnwrap(M1ChannelIdentifier("CUSTOM"))
        let result = try M1ProcessingBuilder.build(
            nodes: [
                M1PreampNode(
                    id: nodeID,
                    isEnabled: true,
                    gainDB: 6,
                    channels: .identifiers([left, missing])
                ),
            ],
            layout: stereoLayout()
        )

        XCTAssertEqual(result.linearGainsByChannel[0], Float(pow(10, 6.0 / 20)), accuracy: 1e-6)
        XCTAssertEqual(result.linearGainsByChannel[1], 1)
        XCTAssertEqual(
            result.diagnostics.unresolvedChannels,
            [M1UnresolvedChannelDiagnostic(nodeID: nodeID, identifiers: [missing])]
        )
        XCTAssertEqual(result.diagnostics.clippingRiskChannels, [left])
    }

    func testAllUnresolvedSelectionsAreNoOpAndPreserveDiagnosticOrder() throws {
        let first = node(
            gainDB: 100,
            channels: .identifiers([identifier("FIRST"), identifier("SECOND")])
        )
        let second = node(gainDB: -100, channels: .identifiers([identifier("THIRD")]))

        let result = try M1ProcessingBuilder.build(nodes: [first, second], layout: stereoLayout())

        XCTAssertEqual(result.linearGainsByChannel, [1, 1])
        XCTAssertEqual(
            result.diagnostics.unresolvedChannels,
            [
                M1UnresolvedChannelDiagnostic(
                    nodeID: first.id,
                    identifiers: [identifier("FIRST"), identifier("SECOND")]
                ),
                M1UnresolvedChannelDiagnostic(nodeID: second.id, identifiers: [identifier("THIRD")]),
            ]
        )
        XCTAssertTrue(result.diagnostics.clippingRiskChannels.isEmpty)
        XCTAssertTrue(result.diagnostics.gainBoundaries.isEmpty)
    }

    func testAllSelectionAndNetGainDrivePerChannelClippingDiagnostics() throws {
        let result = try M1ProcessingBuilder.build(
            nodes: [
                node(gainDB: 6, channels: .all),
                node(gainDB: -3, channels: .all),
                node(gainDB: -3, channels: .identifiers([identifier("R")])),
            ],
            layout: stereoLayout()
        )

        XCTAssertEqual(result.linearGainsByChannel[0], Float(pow(10, 3.0 / 20)), accuracy: 1e-6)
        XCTAssertEqual(result.linearGainsByChannel[1], 1, accuracy: 1e-6)
        XCTAssertEqual(result.diagnostics.clippingRiskChannels, [identifier("L")])
    }

    func testDisabledNodeIsValidatedButDoesNotCompileOrProduceDiagnostics() throws {
        let disabled = M1PreampNode(
            id: UUID(),
            isEnabled: false,
            gainDB: 100,
            channels: .identifiers([identifier("MISSING")])
        )

        let result = try M1ProcessingBuilder.build(nodes: [disabled], layout: stereoLayout())
        XCTAssertEqual(result.linearGainsByChannel, [1, 1])
        XCTAssertTrue(result.diagnostics.unresolvedChannels.isEmpty)
        XCTAssertTrue(result.diagnostics.clippingRiskChannels.isEmpty)

        let invalidDisabled = M1PreampNode(
            id: UUID(),
            isEnabled: false,
            gainDB: 101,
            channels: .all
        )
        XCTAssertThrowsError(
            try M1ProcessingBuilder.build(nodes: [invalidDisabled], layout: stereoLayout())
        ) { error in
            XCTAssertEqual(error as? M1ProcessingBuildError, .gainOutOfRange(nodeID: invalidDisabled.id))
        }

        let nonFiniteDisabled = M1PreampNode(
            id: UUID(),
            isEnabled: false,
            gainDB: .nan,
            channels: .all
        )
        XCTAssertThrowsError(
            try M1ProcessingBuilder.build(nodes: [nonFiniteDisabled], layout: stereoLayout())
        ) { error in
            XCTAssertEqual(error as? M1ProcessingBuildError, .nonFiniteGain(nodeID: nonFiniteDisabled.id))
        }

        let emptyDisabled = M1PreampNode(
            id: UUID(),
            isEnabled: false,
            gainDB: 0,
            channels: .identifiers([])
        )
        XCTAssertThrowsError(
            try M1ProcessingBuilder.build(nodes: [emptyDisabled], layout: stereoLayout())
        ) { error in
            XCTAssertEqual(error as? M1ProcessingBuildError, .emptyChannelSelection(nodeID: emptyDisabled.id))
        }

        let duplicate = identifier("L")
        let duplicateDisabled = M1PreampNode(
            id: UUID(),
            isEnabled: false,
            gainDB: 0,
            channels: .identifiers([duplicate, duplicate])
        )
        XCTAssertThrowsError(
            try M1ProcessingBuilder.build(nodes: [duplicateDisabled], layout: stereoLayout())
        ) { error in
            XCTAssertEqual(
                error as? M1ProcessingBuildError,
                .duplicateChannelIdentifier(nodeID: duplicateDisabled.id, identifier: duplicate)
            )
        }

        let disabledBoundaryNodes = (0..<8).map { _ in
            M1PreampNode(id: UUID(), isEnabled: false, gainDB: 100, channels: .all)
        }
        let disabledBoundaryResult = try M1ProcessingBuilder.build(
            nodes: disabledBoundaryNodes,
            layout: stereoLayout()
        )
        XCTAssertEqual(disabledBoundaryResult.linearGainsByChannel, [1, 1])
        XCTAssertTrue(disabledBoundaryResult.diagnostics.gainBoundaries.isEmpty)
    }

    func testValidationRejectsCandidateWithoutPartialResult() throws {
        let duplicateID = UUID()
        let duplicateNodes = [
            node(id: duplicateID, gainDB: 0, channels: .all),
            node(id: duplicateID, gainDB: 0, channels: .all),
        ]
        XCTAssertThrowsError(
            try M1ProcessingBuilder.build(nodes: duplicateNodes, layout: stereoLayout())
        ) { error in
            XCTAssertEqual(error as? M1ProcessingBuildError, .duplicateNodeID(duplicateID))
        }

        for invalidGain in [Double.nan, Double.infinity, -Double.infinity] {
            let invalid = node(gainDB: invalidGain, channels: .all)
            XCTAssertThrowsError(
                try M1ProcessingBuilder.build(nodes: [invalid], layout: stereoLayout())
            ) { error in
                XCTAssertEqual(error as? M1ProcessingBuildError, .nonFiniteGain(nodeID: invalid.id))
            }
        }

        for invalidGain in [-100.1, 100.1] {
            let invalid = node(gainDB: invalidGain, channels: .all)
            XCTAssertThrowsError(
                try M1ProcessingBuilder.build(nodes: [invalid], layout: stereoLayout())
            ) { error in
                XCTAssertEqual(error as? M1ProcessingBuildError, .gainOutOfRange(nodeID: invalid.id))
            }
        }


        let endpoints = try M1ProcessingBuilder.build(
            nodes: [
                node(gainDB: -100, channels: .identifiers([identifier("L")])),
                node(gainDB: 100, channels: .identifiers([identifier("R")])),
            ],
            layout: stereoLayout()
        )
        XCTAssertGreaterThan(endpoints.linearGainsByChannel[0], 0)
        XCTAssertLessThan(endpoints.linearGainsByChannel[0], 1)
        XCTAssertGreaterThan(endpoints.linearGainsByChannel[1], 1)

        let empty = node(gainDB: 0, channels: .identifiers([]))
        XCTAssertThrowsError(
            try M1ProcessingBuilder.build(nodes: [empty], layout: stereoLayout())
        ) { error in
            XCTAssertEqual(error as? M1ProcessingBuildError, .emptyChannelSelection(nodeID: empty.id))
        }

        let left = identifier("L")
        let duplicateSelection = node(gainDB: 0, channels: .identifiers([left, left]))
        XCTAssertThrowsError(
            try M1ProcessingBuilder.build(nodes: [duplicateSelection], layout: stereoLayout())
        ) { error in
            XCTAssertEqual(
                error as? M1ProcessingBuildError,
                .duplicateChannelIdentifier(nodeID: duplicateSelection.id, identifier: left)
            )
        }
    }

    func testCanonicalSummationAllowsCancellationAndIgnoresNodeReordering() throws {
        let firstOrder = [100.0, -100.0, 5e-15]
        let secondOrder = [100.0, 5e-15, -100.0]

        let grouped = try M1ProcessingBuilder.build(
            nodes: firstOrder.map { node(gainDB: $0, channels: .all) },
            layout: stereoLayout()
        )
        let interleaved = try M1ProcessingBuilder.build(
            nodes: secondOrder.map { node(gainDB: $0, channels: .all) },
            layout: stereoLayout()
        )

        XCTAssertEqual(grouped.linearGainsByChannel, [1, 1])
        XCTAssertEqual(interleaved.linearGainsByChannel, grouped.linearGainsByChannel)
        XCTAssertEqual(grouped.stagesByChannel, [[], []])
        XCTAssertEqual(interleaved.stagesByChannel, grouped.stagesByChannel)
        XCTAssertTrue(grouped.diagnostics.gainBoundaries.isEmpty)
        XCTAssertTrue(grouped.diagnostics.clippingRiskChannels.isEmpty)
    }

    func testFloat32TargetBoundariesAreFiniteAndDiagnosedPerChannel() throws {
        let left = identifier("L")
        let right = identifier("R")
        let highNodes = (0..<8).map { _ in
            node(gainDB: 100, channels: .identifiers([left]))
        }
        let lowNodes = (0..<8).map { _ in
            node(gainDB: -100, channels: .identifiers([right]))
        }

        let result = try M1ProcessingBuilder.build(
            nodes: highNodes + lowNodes,
            layout: stereoLayout()
        )

        XCTAssertEqual(result.linearGainsByChannel, [Float.greatestFiniteMagnitude, 0])
        XCTAssertTrue(result.linearGainsByChannel.allSatisfy { $0.isFinite })
        XCTAssertEqual(
            result.diagnostics.gainBoundaries,
            [
                M1GainBoundaryDiagnostic(channel: left, boundary: .maximumFinite),
                M1GainBoundaryDiagnostic(channel: right, boundary: .zeroBelowMinimumNormal),
            ]
        )
        XCTAssertEqual(result.diagnostics.clippingRiskChannels, [left])
    }

    func testFloat32BoundaryEqualityAndAdjacentTotalsAreStable() throws {
        let maximumDB = 20 * log10(Double(Float.greatestFiniteMagnitude))
        let minimumDB = 20 * log10(Double(Float.leastNormalMagnitude))

        let exactMaximum = try buildAllChannels(totalGainDB: maximumDB)
        XCTAssertEqual(exactMaximum.linearGainsByChannel, [Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude])
        XCTAssertTrue(exactMaximum.diagnostics.gainBoundaries.isEmpty)

        let aboveMaximum = try buildAllChannels(totalGainDB: maximumDB.nextUp)
        XCTAssertEqual(aboveMaximum.linearGainsByChannel, [Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude])
        XCTAssertEqual(
            aboveMaximum.diagnostics.gainBoundaries.map(\.boundary),
            [.maximumFinite, .maximumFinite]
        )

        let belowMaximum = try buildAllChannels(totalGainDB: maximumDB.nextDown)
        XCTAssertTrue(belowMaximum.linearGainsByChannel.allSatisfy { $0.isNormal })
        XCTAssertTrue(belowMaximum.diagnostics.gainBoundaries.isEmpty)

        let exactMinimum = try buildAllChannels(totalGainDB: minimumDB)
        XCTAssertEqual(exactMinimum.linearGainsByChannel, [Float.leastNormalMagnitude, Float.leastNormalMagnitude])
        XCTAssertTrue(exactMinimum.diagnostics.gainBoundaries.isEmpty)

        let belowMinimum = try buildAllChannels(totalGainDB: minimumDB.nextDown)
        XCTAssertEqual(belowMinimum.linearGainsByChannel, [0, 0])
        XCTAssertEqual(
            belowMinimum.diagnostics.gainBoundaries.map(\.boundary),
            [.zeroBelowMinimumNormal, .zeroBelowMinimumNormal]
        )

        let aboveMinimum = try buildAllChannels(totalGainDB: minimumDB.nextUp)
        XCTAssertTrue(aboveMinimum.linearGainsByChannel.allSatisfy { $0.isNormal })
        XCTAssertTrue(aboveMinimum.diagnostics.gainBoundaries.isEmpty)

        for result in [
            exactMaximum,
            aboveMaximum,
            belowMaximum,
            exactMinimum,
            belowMinimum,
            aboveMinimum,
        ] {
            XCTAssertTrue(
                result.linearGainsByChannel.allSatisfy { $0 == 0 || ($0.isFinite && $0.isNormal) }
            )
        }
    }

    func testSameTypedSelectionRecompilesAgainstEachLayoutWithoutMutation() throws {
        let left = identifier("L")
        let configuredNode = node(gainDB: 6, channels: .identifiers([left]))
        let semantic = try M1ProcessingBuilder.build(
            nodes: [configuredNode],
            layout: stereoLayout()
        )
        let numericLayout = try XCTUnwrap(
            M1OutputLayoutSnapshot(
                sampleRate: 48_000,
                maximumFrameCount: 128,
                bufferChannelCounts: [2],
                semanticPositionsByChannelIndex: [nil, nil]
            )
        )
        let numeric = try M1ProcessingBuilder.build(
            nodes: [configuredNode],
            layout: numericLayout
        )

        XCTAssertGreaterThan(semantic.linearGainsByChannel[0], 1)
        XCTAssertEqual(numeric.linearGainsByChannel, [1, 1])
        XCTAssertEqual(
            numeric.diagnostics.unresolvedChannels,
            [M1UnresolvedChannelDiagnostic(nodeID: configuredNode.id, identifiers: [left])]
        )
        XCTAssertEqual(configuredNode.channels, .identifiers([left]))
    }

    func testNumericIdentifiersRemainPhysicalChannelAliasesForSemanticLayouts() throws {
        let configuredNode = node(gainDB: 6, channels: .identifiers([identifier("1")]))
        let result = try M1ProcessingBuilder.build(
            nodes: [configuredNode],
            layout: stereoLayout()
        )

        XCTAssertGreaterThan(result.linearGainsByChannel[0], 1)
        XCTAssertEqual(result.linearGainsByChannel[1], 1)
        XCTAssertTrue(result.diagnostics.unresolvedChannels.isEmpty)
    }
    func testSemanticAndNumericAliasesResolveEachPhysicalChannelOnce() throws {
        let configuredNode = node(
            gainDB: 6,
            channels: .identifiers([identifier("L"), identifier("1")])
        )

        let result = try M1ProcessingBuilder.build(
            nodes: [configuredNode],
            layout: stereoLayout()
        )

        XCTAssertEqual(
            result.linearGainsByChannel[0],
            Float(pow(10, 6.0 / 20)),
            accuracy: 1e-6
        )
        XCTAssertEqual(result.linearGainsByChannel[1], 1)
        XCTAssertEqual(result.stagesByChannel[0].count, 1)
    }

    func testChannelsNodesScopeFollowingEffectsAndAttachUnresolvedDiagnosticsToScope() throws {
        let leftScopeID = UUID()
        let missingScopeID = UUID()
        let left = identifier("L")
        let missing = identifier("CUSTOM")
        let result = try M1ProcessingBuilder.build(
            nodes: [
                .channels(id: leftScopeID, selection: .identifiers([left])),
                node(gainDB: -6, channels: .all),
                .channels(id: missingScopeID, selection: .identifiers([missing])),
                node(gainDB: 12, channels: .all),
                node(gainDB: -4, channels: .all),
                .channels(selection: .all),
                node(gainDB: 3, channels: .all),
            ],
            layout: stereoLayout()
        )

        XCTAssertEqual(result.linearGainsByChannel[0], Float(pow(10, -3.0 / 20)), accuracy: 1e-6)
        XCTAssertEqual(result.linearGainsByChannel[1], Float(pow(10, 3.0 / 20)), accuracy: 1e-6)
        XCTAssertEqual(
            result.diagnostics.unresolvedChannels,
            [M1UnresolvedChannelDiagnostic(nodeID: missingScopeID, identifiers: [missing])]
        )
    }

    func testDisabledChannelsNodeDoesNotChangeFollowingScope() throws {
        let left = identifier("L")
        let result = try M1ProcessingBuilder.build(
            nodes: [
                .channels(selection: .identifiers([left])),
                .channels(isEnabled: false, selection: .identifiers([identifier("R")])),
                node(gainDB: 6, channels: .all),
            ],
            layout: stereoLayout()
        )

        XCTAssertGreaterThan(result.linearGainsByChannel[0], 1)
        XCTAssertEqual(result.linearGainsByChannel[1], 1)
    }

    func testGraphicEQCompilesScopedConvolutionAndOmitsFlatCurves() throws {
        let scopeID = UUID()
        let eq = M1ProcessingNode.graphicEQ(
            id: UUID(),
            points: [
                M1GraphicEQPoint(frequencyHz: 25, gainDB: 3),
                M1GraphicEQPoint(frequencyHz: 630, gainDB: -6),
                M1GraphicEQPoint(frequencyHz: 16_000, gainDB: 0),
            ]
        )
        let result = try M1ProcessingBuilder.build(
            nodes: [
                .channels(id: scopeID, selection: .identifiers([identifier("L")])),
                eq,
            ],
            layout: stereoLayout()
        )

        XCTAssertEqual(result.linearGainsByChannel, [1, 1])
        XCTAssertEqual(result.stagesByChannel[0].count, 1)
        XCTAssertTrue(result.stagesByChannel[1].isEmpty)
        guard case let .convolution(nodeID, taps) = result.stagesByChannel[0][0] else {
            return XCTFail("expected Graphic EQ convolution stage")
        }
        XCTAssertEqual(nodeID, eq.id)
        XCTAssertEqual(taps.count, M1ProcessingBuilder.graphicEQTapCount(forSampleRate: 48_000))
        XCTAssertTrue(taps.contains { $0 != 0 })

        let empty = try M1ProcessingBuilder.build(
            nodes: [.graphicEQ()],
            layout: stereoLayout()
        )
        XCTAssertEqual(empty.stagesByChannel, [[], []])

        let allZero = try M1ProcessingBuilder.build(
            nodes: [
                .graphicEQ(
                    points: [
                        M1GraphicEQPoint(frequencyHz: 20, gainDB: 0),
                        M1GraphicEQPoint(frequencyHz: 2_000, gainDB: 0),
                        M1GraphicEQPoint(frequencyHz: 20_000, gainDB: 0),
                    ]
                )
            ],
            layout: stereoLayout()
        )
        XCTAssertEqual(allZero.stagesByChannel, [[], []])
    }

    func testGraphicEQCurveUsesConstantEndpointsLogMidpointsAndAboveNyquistAnchors() {
        let points = [
            M1GraphicEQPoint(frequencyHz: 20, gainDB: -12),
            M1GraphicEQPoint(frequencyHz: 2_000, gainDB: 12),
            M1GraphicEQPoint(frequencyHz: 20_000, gainDB: 6),
        ]

        XCTAssertEqual(M1ProcessingBuilder.graphicEQGainDB(frequencyHz: 10, points: points), -12)
        XCTAssertEqual(M1ProcessingBuilder.graphicEQGainDB(frequencyHz: 60_000, points: points), 6)
        XCTAssertEqual(
            M1ProcessingBuilder.graphicEQGainDB(
                frequencyHz: sqrt(20 * 2_000),
                points: points
            ),
            0,
            accuracy: 1e-12
        )

        let highAnchorPoints = [
            M1GraphicEQPoint(frequencyHz: 1_000, gainDB: -6),
            M1GraphicEQPoint(frequencyHz: 20_000, gainDB: 6),
        ]
        let nyquist = 32_000.0 / 2
        let expected = -6
            + (log(nyquist) - log(1_000)) / (log(20_000) - log(1_000)) * 12
        XCTAssertEqual(
            M1ProcessingBuilder.graphicEQGainDB(
                frequencyHz: nyquist,
                points: highAnchorPoints
            ),
            expected,
            accuracy: 1e-12
        )
    }

    func testGraphicEQValidationRejectsInvalidPointShapeAndGain() {
        let tooManyID = UUID()
        let tooMany = M1ProcessingNode.graphicEQ(
            id: tooManyID,
            points: makeGraphicEQPoints(count: M1GraphicEQContract.maximumPointCount + 1)
        )
        XCTAssertThrowsError(try M1ProcessingBuilder.validate(nodes: [tooMany])) {
            XCTAssertEqual(
                $0 as? M1ProcessingBuildError,
                .invalidGraphicEQBandCount(nodeID: tooManyID)
            )
        }

        let unsortedID = UUID()
        let unsorted = M1ProcessingNode.graphicEQ(
            id: unsortedID,
            points: [
                M1GraphicEQPoint(frequencyHz: 100, gainDB: 0),
                M1GraphicEQPoint(frequencyHz: 20, gainDB: 0),
            ]
        )
        XCTAssertThrowsError(try M1ProcessingBuilder.validate(nodes: [unsorted])) {
            XCTAssertEqual(
                $0 as? M1ProcessingBuildError,
                .invalidGraphicEQFrequency(nodeID: unsortedID, bandIndex: 1)
            )
        }

        let duplicateID = UUID()
        let duplicate = M1ProcessingNode.graphicEQ(
            id: duplicateID,
            points: [
                M1GraphicEQPoint(frequencyHz: 20, gainDB: 0),
                M1GraphicEQPoint(frequencyHz: 20, gainDB: 1),
            ]
        )
        XCTAssertThrowsError(try M1ProcessingBuilder.validate(nodes: [duplicate])) {
            XCTAssertEqual(
                $0 as? M1ProcessingBuildError,
                .invalidGraphicEQFrequency(nodeID: duplicateID, bandIndex: 1)
            )
        }

        let nonFiniteID = UUID()
        let nonFinite = M1ProcessingNode.graphicEQ(
            id: nonFiniteID,
            points: [
                M1GraphicEQPoint(frequencyHz: 20, gainDB: 0),
                M1GraphicEQPoint(frequencyHz: 2_000, gainDB: .nan),
            ]
        )
        XCTAssertThrowsError(try M1ProcessingBuilder.validate(nodes: [nonFinite])) {
            XCTAssertEqual(
                $0 as? M1ProcessingBuildError,
                .nonFiniteGraphicEQGain(nodeID: nonFiniteID, bandIndex: 1)
            )
        }

        let outOfProcessingRange = M1ProcessingNode.graphicEQ(
            points: [M1GraphicEQPoint(frequencyHz: 200_000, gainDB: 0)]
        )
        XCTAssertNoThrow(try M1ProcessingBuilder.validate(nodes: [outOfProcessingRange]))

        let outOfRangeID = UUID()
        let outOfRange = M1ProcessingNode.graphicEQ(
            id: outOfRangeID,
            points: [M1GraphicEQPoint(frequencyHz: 20, gainDB: 24.1)]
        )
        XCTAssertThrowsError(try M1ProcessingBuilder.validate(nodes: [outOfRange])) {
            XCTAssertEqual(
                $0 as? M1ProcessingBuildError,
                .graphicEQGainOutOfRange(nodeID: outOfRangeID, bandIndex: 0)
            )
        }
    }

    func testGraphicEQPreservesButDoesNotProcessOutOfRangePoints() throws {
        let outsideOnly = M1ProcessingNode.graphicEQ(points: [
            M1GraphicEQPoint(frequencyHz: 10, gainDB: -6),
            M1GraphicEQPoint(frequencyHz: 30_000, gainDB: 6),
        ])
        XCTAssertEqual(
            try M1ProcessingBuilder.build(nodes: [outsideOnly], layout: monoLayout())
                .stagesByChannel,
            [[]]
        )

        let activePoints = [
            M1GraphicEQPoint(frequencyHz: 1_000, gainDB: 3),
        ]
        let pointsWithOutside = [
            M1GraphicEQPoint(frequencyHz: 10, gainDB: -6),
            M1GraphicEQPoint(frequencyHz: 1_000, gainDB: 3),
            M1GraphicEQPoint(frequencyHz: 30_000, gainDB: -6),
        ]
        for frequency in [20.0, 100.0, 1_000.0, 10_000.0, 20_000.0] {
            XCTAssertEqual(
                M1ProcessingBuilder.graphicEQProcessingGainDB(
                    frequencyHz: frequency,
                    points: pointsWithOutside
                ),
                M1ProcessingBuilder.graphicEQProcessingGainDB(
                    frequencyHz: frequency,
                    points: activePoints
                ),
                accuracy: 1e-12
            )
        }
        XCTAssertEqual(
            M1ProcessingBuilder.graphicEQProcessingGainDB(
                frequencyHz: 30_000,
                points: pointsWithOutside
            ),
            0
        )

        let activeBuild = try M1ProcessingBuilder.build(
            nodes: [.graphicEQ(points: activePoints)],
            layout: monoLayout()
        )
        let outsideBuild = try M1ProcessingBuilder.build(
            nodes: [.graphicEQ(points: pointsWithOutside)],
            layout: monoLayout()
        )
        guard case let .convolution(_, activeTaps) = activeBuild.stagesByChannel[0][0],
              case let .convolution(_, outsideTaps) = outsideBuild.stagesByChannel[0][0] else {
            return XCTFail("expected Graphic EQ convolution stages")
        }
        XCTAssertEqual(outsideTaps, activeTaps)
    }

    func testGraphicEQAndWAVConvolutionShareOnlyInstanceCapacity() throws {
        let mono = monoLayout()
        let eqNodes = (0..<7).map { offset in
            nonFlatGraphicEQ(id: UUID(), gainDB: Double(offset + 1))
        }

        let shortReference = convolutionReference(storageID: UUID(), frameCount: 1)
        let shortLoader = MockConvolutionIRLoader(loadedBySourcePath: [
            shortReference.sourcePath: M1LoadedConvolutionIR(
                source: shortReference,
                sourceSampleRate: mono.sampleRate,
                sourceChannelCount: 1,
                sourceFrameCount: 1,
                targetSampleRate: mono.sampleRate,
                channels: [[1]]
            )
        ])
        let passing = try M1ProcessingBuilder.build(
            nodes: eqNodes + [.convolution(ir: shortReference)],
            layout: mono,
            irLoader: shortLoader
        )
        XCTAssertEqual(passing.stagesByChannel[0].count, 8)

        XCTAssertThrowsError(try M1ProcessingBuilder.build(
            nodes: eqNodes + [nonFlatGraphicEQ(id: UUID(), gainDB: 9), .convolution(ir: shortReference)],
            layout: mono,
            irLoader: shortLoader
        )) {
            XCTAssertEqual($0 as? M1ProcessingBuildError, .convolutionStageCapacityExceeded)
        }

        let longTapCount = 16_385
        let longReference = convolutionReference(storageID: UUID(), frameCount: longTapCount)
        let longLoader = MockConvolutionIRLoader(loadedBySourcePath: [
            longReference.sourcePath: M1LoadedConvolutionIR(
                source: longReference,
                sourceSampleRate: mono.sampleRate,
                sourceChannelCount: 1,
                sourceFrameCount: longTapCount,
                targetSampleRate: mono.sampleRate,
                channels: [impulse(count: longTapCount)]
            )
        ])
        let longBuild = try M1ProcessingBuilder.build(
            nodes: eqNodes + [.convolution(ir: longReference)],
            layout: mono,
            irLoader: longLoader
        )
        XCTAssertEqual(longBuild.stagesByChannel[0].count, 8)
    }

    func testGraphicEQRepresentativeFIRResponseStaysWithinBroadSlopeTolerance() throws {
        let points = [
            M1GraphicEQPoint(frequencyHz: 20, gainDB: -6),
            M1GraphicEQPoint(frequencyHz: 80, gainDB: -3),
            M1GraphicEQPoint(frequencyHz: 1_000, gainDB: 0),
            M1GraphicEQPoint(frequencyHz: 8_000, gainDB: 3),
            M1GraphicEQPoint(frequencyHz: 20_000, gainDB: 6),
        ]

        for sampleRate in [44_100.0, 48_000.0, 96_000.0, 192_000.0] {
            let compiled = try M1ProcessingBuilder.build(
                nodes: [M1ProcessingNode.graphicEQ(id: UUID(), points: points)],
                layout: monoLayout(sampleRate: sampleRate)
            )
            guard case let .convolution(_, taps) = compiled.stagesByChannel[0][0] else {
                return XCTFail("expected Graphic EQ convolution stage at \(sampleRate) Hz")
            }
            XCTAssertEqual(
                taps.count,
                M1ProcessingBuilder.graphicEQTapCount(forSampleRate: sampleRate),
                "sampleRate=\(sampleRate)"
            )

            let frequencies = logarithmicFrequencies(
                minimum: M1GraphicEQContract.minimumResponseEvaluationFrequencyHz,
                maximum: min(
                    M1GraphicEQContract.maximumResponseEvaluationFrequencyHz,
                    sampleRate * 0.45
                ),
                count: 193
            )
            let errors = frequencies.map { frequencyHz in
                abs(
                    responseDB(taps: taps, frequencyHz: frequencyHz, sampleRate: sampleRate)
                        - M1ProcessingBuilder.graphicEQProcessingGainDB(
                            frequencyHz: frequencyHz,
                            points: points
                        )
                )
            }.sorted()
            let p99Index = min(errors.count - 1, Int(Double(errors.count - 1) * 0.99))
            let p99 = errors[p99Index]
            let maximum = errors.last ?? .infinity

            XCTAssertLessThanOrEqual(maximum, 0.75, "sampleRate=\(sampleRate) max=\(maximum)")
            XCTAssertLessThanOrEqual(p99, 0.1, "sampleRate=\(sampleRate) p99=\(p99)")
        }
    }

    func testGraphicEQTapCountScalesWithSampleRatePerADR0020() {
        let cases: [(Double, Int)] = [
            (8_000, 16_384),
            (44_100, 16_384),
            (48_000, 16_384),
            (48_000.1, 32_768),
            (88_200, 32_768),
            (96_000, 32_768),
            (176_400, 65_536),
            (192_000, 65_536),
            (384_000, 131_072),
            (0, 16_384),
            (-1, 16_384),
            (.nan, 16_384),
        ]
        for (sampleRate, expected) in cases {
            XCTAssertEqual(
                M1ProcessingBuilder.graphicEQTapCount(forSampleRate: sampleRate),
                expected,
                "sampleRate=\(sampleRate)"
            )
            XCTAssertEqual(
                M1ProcessingBuilder.graphicEQDesignLength(forSampleRate: sampleRate),
                expected * 2,
                "designLength sampleRate=\(sampleRate)"
            )
        }
    }

    func testGraphicEQLowSampleRateTapsMatchLegacyFixedLength() throws {
        let points = [
            M1GraphicEQPoint(frequencyHz: 20, gainDB: -6),
            M1GraphicEQPoint(frequencyHz: 80, gainDB: -3),
            M1GraphicEQPoint(frequencyHz: 1_000, gainDB: 0),
            M1GraphicEQPoint(frequencyHz: 8_000, gainDB: 3),
            M1GraphicEQPoint(frequencyHz: 20_000, gainDB: 6),
        ]
        for sampleRate in [44_100.0, 48_000.0] {
            let compiled = try M1ProcessingBuilder.build(
                nodes: [M1ProcessingNode.graphicEQ(id: UUID(), points: points)],
                layout: monoLayout(sampleRate: sampleRate)
            )
            guard case let .convolution(_, taps) = compiled.stagesByChannel[0][0] else {
                return XCTFail("expected Graphic EQ convolution at \(sampleRate)")
            }
            XCTAssertEqual(taps.count, M1ProcessingBuilder.graphicEQTapCount)
            XCTAssertEqual(taps.count, 16_384)
            XCTAssertTrue(taps.contains { $0 != 0 })
        }
    }

    func testGraphicEQScaledLengthImprovesDenseLowFrequencyAt192k() throws {
        // Feature scale ~20 Hz in the low band: fixed 16k taps at 192 kHz (~11.7 Hz
        // bins) under-resolve; scaled 65k (~2.9 Hz bins) meets the contract.
        let points = [
            M1GraphicEQPoint(frequencyHz: 20, gainDB: -6),
            M1GraphicEQPoint(frequencyHz: 40, gainDB: 6),
            M1GraphicEQPoint(frequencyHz: 80, gainDB: -3),
            M1GraphicEQPoint(frequencyHz: 200, gainDB: 0),
            M1GraphicEQPoint(frequencyHz: 1_000, gainDB: 0),
            M1GraphicEQPoint(frequencyHz: 20_000, gainDB: 0),
        ]

        let sampleRate = 192_000.0
        let scaled = try M1ProcessingBuilder.build(
            nodes: [M1ProcessingNode.graphicEQ(id: UUID(), points: points)],
            layout: monoLayout(sampleRate: sampleRate)
        )
        guard case let .convolution(_, scaledTaps) = scaled.stagesByChannel[0][0] else {
            return XCTFail("expected scaled Graphic EQ convolution")
        }
        XCTAssertEqual(scaledTaps.count, 65_536)

        let frequencies = logarithmicFrequencies(
            minimum: M1GraphicEQContract.minimumResponseEvaluationFrequencyHz,
            maximum: min(
                M1GraphicEQContract.maximumResponseEvaluationFrequencyHz,
                sampleRate * 0.45
            ),
            count: 193
        )
        func errors(for taps: [Float]) -> (max: Double, p99: Double) {
            let values = frequencies.map { frequencyHz in
                abs(
                    responseDB(taps: taps, frequencyHz: frequencyHz, sampleRate: sampleRate)
                        - M1ProcessingBuilder.graphicEQProcessingGainDB(
                            frequencyHz: frequencyHz,
                            points: points
                        )
                )
            }.sorted()
            let p99 = values[min(values.count - 1, Int(Double(values.count - 1) * 0.99))]
            return (values.last ?? .infinity, p99)
        }

        let scaledErrors = errors(for: scaledTaps)
        XCTAssertLessThanOrEqual(
            scaledErrors.max,
            M1ProcessingBuilder.graphicEQMaximumResponseErrorDB,
            "scaled max=\(scaledErrors.max)"
        )
        XCTAssertLessThanOrEqual(
            scaledErrors.p99,
            M1ProcessingBuilder.graphicEQPercentile99ResponseErrorDB,
            "scaled p99=\(scaledErrors.p99)"
        )
        XCTAssertTrue(scaled.diagnostics.graphicEQResolution.isEmpty)

        let fixedTaps = try XCTUnwrap(
            try M1ProcessingBuilder.graphicEQCompiledTaps(
                points: points,
                sampleRate: sampleRate,
                tapCount: 16_384
            )
        )
        XCTAssertEqual(fixedTaps.count, 16_384)
        let fixedErrors = errors(for: fixedTaps)
        XCTAssertTrue(
            fixedErrors.max > M1ProcessingBuilder.graphicEQMaximumResponseErrorDB
                || fixedErrors.p99 > M1ProcessingBuilder.graphicEQPercentile99ResponseErrorDB,
            "fixed 16k taps at 192 kHz must fail; max=\(fixedErrors.max) p99=\(fixedErrors.p99)"
        )
        XCTAssertLessThan(
            scaledErrors.max,
            fixedErrors.max,
            "scaled must improve absolute tracking error"
        )
    }

    func testGraphicEQConstantActiveCurveKeepsOutOfDomainTargetNeutral() throws {
        let gainDB = 6.0
        let result = try M1ProcessingBuilder.build(
            nodes: [
                .graphicEQ(points: [
                    M1GraphicEQPoint(frequencyHz: 20, gainDB: gainDB),
                    M1GraphicEQPoint(frequencyHz: 20_000, gainDB: gainDB),
                ])
            ],
            layout: monoLayout()
        )
        guard case let .convolution(_, taps) = result.stagesByChannel[0][0] else {
            return XCTFail("expected convolution")
        }
        XCTAssertEqual(
            responseDB(taps: taps, frequencyHz: 1_000, sampleRate: 48_000),
            gainDB,
            accuracy: 0.1
        )
        XCTAssertEqual(
            M1ProcessingBuilder.graphicEQProcessingGainDB(
                frequencyHz: 10,
                points: [
                    M1GraphicEQPoint(frequencyHz: 20, gainDB: gainDB),
                    M1GraphicEQPoint(frequencyHz: 20_000, gainDB: gainDB),
                ]
            ),
            0
        )
        XCTAssertGreaterThan(taps.dropFirst().map { abs($0) }.max() ?? 0, 1e-5)
    }

    func testGraphicEQChannelInstancesUseSharedCapacityBoundary() throws {
        let node = nonFlatGraphicEQ(gainDB: 6)
        let eightChannels = try XCTUnwrap(M1OutputLayoutSnapshot(
            sampleRate: 48_000,
            maximumFrameCount: 256,
            bufferChannelCounts: [8],
            semanticPositionsByChannelIndex: Array(repeating: nil, count: 8)
        ))
        XCTAssertEqual(
            try M1ProcessingBuilder.build(nodes: [node], layout: eightChannels)
                .stagesByChannel.flatMap { $0 }.count,
            8
        )

        let nineChannels = try XCTUnwrap(M1OutputLayoutSnapshot(
            sampleRate: 48_000,
            maximumFrameCount: 256,
            bufferChannelCounts: [9],
            semanticPositionsByChannelIndex: Array(repeating: nil, count: 9)
        ))
        XCTAssertThrowsError(try M1ProcessingBuilder.build(nodes: [node], layout: nineChannels)) {
            XCTAssertEqual($0 as? M1ProcessingBuildError, .convolutionStageCapacityExceeded)
        }
    }

    func testGraphicEQPreviewCoversNyquistOrTwentyKilohertz() throws {
        let points = [
            M1GraphicEQPoint(frequencyHz: 20, gainDB: 0),
            M1GraphicEQPoint(frequencyHz: 1_000, gainDB: 6),
            M1GraphicEQPoint(frequencyHz: 20_000, gainDB: 0),
        ]
        for sampleRate in [48_000.0, 96_000.0, 192_000.0] {
            let preview = try M1ProcessingBuilder.graphicEQPreview(
                points: points,
                sampleRate: sampleRate
            )
            XCTAssertEqual(
                try XCTUnwrap(preview.frequenciesHz.last),
                min(20_000, sampleRate / 2),
                accuracy: 1e-9
            )
        }
    }

    func testGraphicEQDenseCurveProducesOwnedResolutionDiagnostic() throws {
        let nodeID = UUID()
        let points = [
            M1GraphicEQPoint(frequencyHz: 20, gainDB: -24),
            M1GraphicEQPoint(frequencyHz: 21, gainDB: 24),
            M1GraphicEQPoint(frequencyHz: 22, gainDB: -24),
            M1GraphicEQPoint(frequencyHz: 20_000, gainDB: 0),
        ]
        let result = try M1ProcessingBuilder.build(
            nodes: [.graphicEQ(id: nodeID, points: points)],
            layout: monoLayout()
        )
        let diagnostic = try XCTUnwrap(result.diagnostics.graphicEQResolution.first)
        XCTAssertEqual(diagnostic.nodeID, nodeID)
        XCTAssertTrue(
            diagnostic.maximumErrorDB > M1ProcessingBuilder.graphicEQMaximumResponseErrorDB
                || diagnostic.percentile99ErrorDB
                    > M1ProcessingBuilder.graphicEQPercentile99ResponseErrorDB
        )

        let preview = try M1ProcessingBuilder.graphicEQPreview(
            points: points,
            sampleRate: 48_000,
            sampleCount: 193
        )
        XCTAssertTrue(
            preview.maximumErrorDB > M1ProcessingBuilder.graphicEQMaximumResponseErrorDB
                || preview.percentile99ErrorDB
                    > M1ProcessingBuilder.graphicEQPercentile99ResponseErrorDB
        )
    }

    func testCompiledScopedStagesProcessThroughRuntimeV3() throws {
        let left = identifier("L")
        let right = identifier("R")
        let equalizer = M1ProcessingNode.graphicEQ(
            points: [
                M1GraphicEQPoint(frequencyHz: 20, gainDB: 0),
                M1GraphicEQPoint(frequencyHz: 1_000, gainDB: 6),
                M1GraphicEQPoint(frequencyHz: 20_000, gainDB: 6),
            ]
        )
        let compiled = try M1ProcessingBuilder.build(
            nodes: [
                .channels(selection: .identifiers([left])),
                node(gainDB: -6, channels: .all),
                equalizer,
                .channels(selection: .identifiers([right])),
                node(gainDB: 3, channels: .all),
            ],
            layout: stereoLayout()
        )
        guard case let .gain(_, leftGain) = compiled.stagesByChannel[0][0],
              case let .convolution(_, taps) = compiled.stagesByChannel[0][1],
              case let .gain(_, rightGain) = compiled.stagesByChannel[1][0]
        else {
            return XCTFail("expected scoped Gain/Convolution execution plan")
        }

        var prepared: OpaquePointer? = try M1RuntimePreparedStateFactory.create(
            stagesByChannel: compiled.stagesByChannel
        )
        var runtime: OpaquePointer?
        var channelCount: UInt32 = 2
        let createStatus = withUnsafePointer(to: &channelCount) { channelCounts in
            var description = EAUM1RuntimeDescription(
                sampleRate: 48_000,
                maximumFrameCount: 16,
                bufferCount: 1,
                channelCounts: channelCounts,
                effectsEnabled: 1
            )
            return EAUM1RuntimeCreate(&description, &prepared, &runtime)
        }
        XCTAssertEqual(Int(createStatus), EAUM1StatusOK)
        XCTAssertNil(prepared)
        let retainedRuntime = try XCTUnwrap(runtime)
        defer { EAUM1RuntimeDestroy(retainedRuntime) }

        var samples: [Float] = [1, 1]
        let status = samples.withUnsafeMutableBufferPointer { values in
            var buffer = EAUM1AudioBuffer(samples: values.baseAddress, channelCount: 2)
            return EAUM1RuntimeProcess(retainedRuntime, &buffer, 1, 1)
        }
        XCTAssertEqual(Int(status), EAUM1StatusOK)
        XCTAssertEqual(samples[0], Float(leftGain) * taps[0], accuracy: 1e-5)
        XCTAssertEqual(samples[1], Float(rightGain), accuracy: 1e-6)
    }

    private func monoLayout(sampleRate: Double = 48_000) -> M1OutputLayoutSnapshot {
        M1OutputLayoutSnapshot(
            sampleRate: sampleRate,
            maximumFrameCount: 512,
            bufferChannelCounts: [1],
            semanticPositionsByChannelIndex: [.left]
        )!
    }

    private func stereoLayout() -> M1OutputLayoutSnapshot {
        M1OutputLayoutSnapshot(
            sampleRate: 48_000,
            maximumFrameCount: 512,
            bufferChannelCounts: [2],
            semanticPositionsByChannelIndex: [.left, .right]
        )!
    }

    private func identifier(_ value: String) -> M1ChannelIdentifier {
        M1ChannelIdentifier(value)!
    }

    private func nonFlatGraphicEQ(id: UUID = UUID(), gainDB: Double) -> M1ProcessingNode {
        M1ProcessingNode.graphicEQ(
            id: id,
            points: [
                M1GraphicEQPoint(frequencyHz: 20, gainDB: 0),
                M1GraphicEQPoint(frequencyHz: 1_000, gainDB: gainDB),
                M1GraphicEQPoint(frequencyHz: 20_000, gainDB: gainDB),
            ]
        )
    }

    private func convolutionReference(
        storageID: UUID,
        frameCount: Int,
        sampleRate: Double = 48_000
    ) -> M1ConvolutionIRReference {
        M1ConvolutionIRReference(
            sourcePath: "/tmp/\(storageID.uuidString).wav"
        )
    }

    private func impulse(count: Int) -> [Float] {
        var taps = Array(repeating: Float.zero, count: count)
        if !taps.isEmpty { taps[0] = 1 }
        return taps
    }

    private func logarithmicFrequencies(
        minimum: Double,
        maximum: Double,
        count: Int
    ) -> [Double] {
        guard count > 1 else { return [minimum] }
        let lower = log(minimum)
        let upper = log(maximum)
        return (0..<count).map { index in
            let fraction = Double(index) / Double(count - 1)
            return exp(lower + (upper - lower) * fraction)
        }
    }

    private func responseDB(
        taps: [Float],
        frequencyHz: Double,
        sampleRate: Double
    ) -> Double {
        let omega = -2 * Double.pi * frequencyHz / sampleRate
        var real = 0.0
        var imag = 0.0
        for (index, tap) in taps.enumerated() {
            let angle = omega * Double(index)
            real += Double(tap) * cos(angle)
            imag += Double(tap) * sin(angle)
        }
        return 20 * log10(max(hypot(real, imag), 1e-12))
    }

    private func makeGraphicEQPoints(count: Int) -> [M1GraphicEQPoint] {
        guard count > 0 else { return [] }
        let lower = log(M1GraphicEQContract.minimumFrequencyHz)
        let upper = log(M1GraphicEQContract.maximumFrequencyHz)
        return (0..<count).map { index in
            let fraction = count == 1 ? 0.0 : Double(index) / Double(count - 1)
            return M1GraphicEQPoint(
                frequencyHz: exp(lower + (upper - lower) * fraction),
                gainDB: -24 + 48 * fraction
            )
        }
    }

    private func buildAllChannels(totalGainDB: Double) throws -> M1CompiledPreampTargets {
        let components = componentsSummingExactly(to: totalGainDB)
        return try M1ProcessingBuilder.build(
            nodes: components.map { node(gainDB: $0, channels: .all) },
            layout: stereoLayout()
        )
    }

    private func componentsSummingExactly(to total: Double) -> [Double] {
        let fullComponent = total.sign == .minus ? -100.0 : 100.0
        let fullComponentCount = Int(abs(total) / 100)
        var components = Array(repeating: fullComponent, count: fullComponentCount)
        var remainder = total - components.reduce(0, +)
        components.append(remainder)

        for _ in 0..<64 {
            let sum = components.sorted().reduce(0, +)
            if sum == total {
                return components
            }
            remainder = sum < total ? remainder.nextUp : remainder.nextDown
            components[components.count - 1] = remainder
        }

        XCTFail("Unable to construct an exact canonical sum for \(total)")
        return components
    }

    private func node(
        id: UUID = UUID(),
        gainDB: Double,
        channels: M1ChannelSelection
    ) -> M1PreampNode {
        M1PreampNode(id: id, isEnabled: true, gainDB: gainDB, channels: channels)
    }
}

private struct MockConvolutionIRLoader: M1ConvolutionIRLoading {
    let loadedBySourcePath: [String: M1LoadedConvolutionIR]

    func load(
        reference: M1ConvolutionIRReference,
        targetSampleRate: Double
    ) throws -> M1LoadedConvolutionIR {
        guard let loaded = loadedBySourcePath[reference.sourcePath] else {
            throw M1ConvolutionIRError.missingResource
        }
        return M1LoadedConvolutionIR(
            source: loaded.source,
            sourceSampleRate: loaded.sourceSampleRate,
            sourceChannelCount: loaded.sourceChannelCount,
            sourceFrameCount: loaded.sourceFrameCount,
            targetSampleRate: targetSampleRate,
            channels: loaded.channels
        )
    }
}
