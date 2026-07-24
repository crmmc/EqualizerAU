import XCTest

final class M1ProcessingBuilderTests: XCTestCase {
    func testSwiftBridgeCreatesPreparedV2FromCompiledGraphicEQStages() throws {
        var equalizer = M1ProcessingNode.graphicEQ(id: UUID())
        equalizer.graphicEQBands[8].gainDB = 6
        let compiled = try M1ProcessingBuilder.build(
            nodes: [equalizer],
            layout: stereoLayout()
        )

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

    func testGraphicEQCompilesOrderedScopedBiquadsAndOmitsFlatBands() throws {
        let scopeID = UUID()
        var eq = M1ProcessingNode.graphicEQ(id: UUID())
        eq.graphicEQBands[0].gainDB = 3
        eq.graphicEQBands[7].gainDB = -6
        let result = try M1ProcessingBuilder.build(
            nodes: [
                .channels(id: scopeID, selection: .identifiers([identifier("L")])),
                eq,
            ],
            layout: stereoLayout()
        )

        XCTAssertEqual(result.linearGainsByChannel, [1, 1])
        XCTAssertEqual(result.stagesByChannel[0].count, 2)
        XCTAssertTrue(result.stagesByChannel[1].isEmpty)
        guard case let .biquad(firstID, firstBand, firstCoefficients) = result.stagesByChannel[0][0],
              case let .biquad(secondID, secondBand, secondCoefficients) = result.stagesByChannel[0][1]
        else {
            return XCTFail("expected ordered biquad stages")
        }
        XCTAssertEqual(firstID, eq.id)
        XCTAssertEqual(secondID, eq.id)
        XCTAssertEqual([firstBand, secondBand], [0, 7])
        XCTAssertTrue([firstCoefficients, secondCoefficients].allSatisfy {
            [$0.b0, $0.b1, $0.b2, $0.a1, $0.a2].allSatisfy(\.isFinite)
        })

        let flat = try M1ProcessingBuilder.build(
            nodes: [.graphicEQ()],
            layout: stereoLayout()
        )
        XCTAssertEqual(flat.stagesByChannel, [[], []])
    }

    func testGraphicEQSkipsBandsAtOrAboveNyquistWithOwnedDiagnostic() throws {
        var eq = M1ProcessingNode.graphicEQ(id: UUID())
        eq.graphicEQBands[14].gainDB = 4
        let layout = M1OutputLayoutSnapshot(
            sampleRate: 32_000,
            maximumFrameCount: 128,
            bufferChannelCounts: [1],
            semanticPositionsByChannelIndex: [.left]
        )!

        let result = try M1ProcessingBuilder.build(nodes: [eq], layout: layout)
        XCTAssertTrue(result.stagesByChannel[0].isEmpty)
        XCTAssertEqual(
            result.diagnostics.unavailableGraphicEQBands,
            [M1UnavailableGraphicEQBandDiagnostic(nodeID: eq.id, frequencyHz: 16_000)]
        )
    }

    func testGraphicEQValidationRejectsInvalidBandShapeAndGain() {
        let id = UUID()
        var missingBand = M1ProcessingNode.graphicEQ(id: id)
        missingBand.graphicEQBands.removeLast()
        XCTAssertThrowsError(try M1ProcessingBuilder.validate(nodes: [missingBand])) {
            XCTAssertEqual($0 as? M1ProcessingBuildError, .invalidGraphicEQBandCount(nodeID: id))
        }

        var nonFinite = M1ProcessingNode.graphicEQ(id: id)
        nonFinite.graphicEQBands[2].gainDB = .nan
        XCTAssertThrowsError(try M1ProcessingBuilder.validate(nodes: [nonFinite])) {
            XCTAssertEqual(
                $0 as? M1ProcessingBuildError,
                .nonFiniteGraphicEQGain(nodeID: id, bandIndex: 2)
            )
        }
    }

    func testBuilderRejectsPreparedTotalStageCapacityBeforePublication() throws {
        let equalizers = (0..<31).map { _ -> M1ProcessingNode in
            var node = M1ProcessingNode.graphicEQ()
            for index in node.graphicEQBands.indices {
                node.graphicEQBands[index].gainDB = 1
            }
            return node
        }
        let layout = try XCTUnwrap(M1OutputLayoutSnapshot(
            sampleRate: 48_000,
            maximumFrameCount: 128,
            bufferChannelCounts: [9],
            semanticPositionsByChannelIndex: Array(repeating: nil, count: 9)
        ))

        XCTAssertThrowsError(try M1ProcessingBuilder.build(nodes: equalizers, layout: layout)) {
            XCTAssertEqual($0 as? M1ProcessingBuildError, .totalStageCapacityExceeded)
        }
    }

    func testCompiledScopedStagesProcessThroughRuntimeV2() throws {
        let left = identifier("L")
        let right = identifier("R")
        var equalizer = M1ProcessingNode.graphicEQ()
        equalizer.graphicEQBands[8].gainDB = 6
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
              case let .biquad(_, _, coefficients) = compiled.stagesByChannel[0][1],
              case let .gain(_, rightGain) = compiled.stagesByChannel[1][0]
        else {
            return XCTFail("expected scoped Gain/Biquad execution plan")
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
        XCTAssertEqual(samples[0], Float(leftGain * coefficients.b0), accuracy: 1e-6)
        XCTAssertEqual(samples[1], Float(rightGain), accuracy: 1e-6)
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
