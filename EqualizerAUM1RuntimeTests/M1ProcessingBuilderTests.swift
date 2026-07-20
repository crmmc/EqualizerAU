import XCTest

final class M1ProcessingBuilderTests: XCTestCase {
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
