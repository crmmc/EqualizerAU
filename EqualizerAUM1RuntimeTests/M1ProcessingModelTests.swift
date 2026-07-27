import XCTest

final class M1ProcessingModelTests: XCTestCase {
    func testConvolutionCopyPreservesImmutableIRAndInheritsChannelsScope() {
        let reference = M1ConvolutionIRReference(
            storageID: UUID(),
            originalFileName: "room.wav",
            sha256: String(repeating: "a", count: 64),
            sampleRate: 48_000,
            channelCount: 1,
            frameCount: 128
        )
        let node = M1ProcessingNode.convolution(ir: reference)
        let copy = node.copied(id: UUID())
        let scope = M1ProcessingNode.channels(
            selection: .identifiers([M1ChannelIdentifier("L")!])
        )

        XCTAssertNotEqual(copy.id, node.id)
        XCTAssertEqual(copy.convolutionIR, reference)
        XCTAssertEqual(
            M1ProcessingScopeResolver.effectiveSelections(nodes: [scope, copy])[copy.id],
            scope.channels
        )
    }

    func testDisabledChannelsDoNotReplaceEffectiveScope() {
        let left = M1ProcessingNode.channels(
            selection: .identifiers([M1ChannelIdentifier("L")!])
        )
        let disabledRight = M1ProcessingNode.channels(
            isEnabled: false,
            selection: .identifiers([M1ChannelIdentifier("R")!])
        )
        let preamp = M1PreampNode(id: UUID(), isEnabled: true, gainDB: 0, channels: .all)

        XCTAssertEqual(
            M1ProcessingScopeResolver.effectiveSelections(
                nodes: [left, disabledRight, preamp]
            )[preamp.id],
            left.channels
        )
    }

    func testGraphicEQFactoryStoresPointsKeepsLegacyBandAliasAndDefaultsFlatToEmpty() {
        let defaultNode = M1ProcessingNode.graphicEQ()
        var node = M1ProcessingNode.graphicEQ(
            id: UUID(),
            points: [
                M1GraphicEQPoint(frequencyHz: 20, gainDB: -3),
                M1GraphicEQPoint(frequencyHz: 2_000, gainDB: 1.5),
                M1GraphicEQPoint(frequencyHz: 20_000, gainDB: 6),
            ]
        )
        node.graphicEQPoints[1].gainDB = 3.5
        let copy = node.copied(id: UUID())

        XCTAssertTrue(defaultNode.graphicEQPoints.isEmpty)
        XCTAssertEqual(node.graphicEQPoints[1].gainDB, 3.5)
        XCTAssertEqual(copy.kind, .graphicEQ)
        XCTAssertNotEqual(copy.id, node.id)
        XCTAssertEqual(copy.graphicEQPoints, node.graphicEQPoints)
        XCTAssertEqual(M1GraphicEQContract.maximumPointCount, 512)
    }

    func testChannelIdentifierCanonicalizesCustomAndNumericValues() {
        XCTAssertEqual(M1ChannelIdentifier(" sub ")?.rawValue, "SUB")
        XCTAssertEqual(M1ChannelIdentifier("001")?.rawValue, "1")
        XCTAssertNil(M1ChannelIdentifier(" "))
        XCTAssertNil(M1ChannelIdentifier("all"))
        XCTAssertNil(M1ChannelIdentifier("0"))
    }

    func testPreampKeepsStableIdentityAndTypedChannelSelection() throws {
        let id = UUID()
        let left = try XCTUnwrap(M1ChannelIdentifier("L"))
        let unresolved = try XCTUnwrap(M1ChannelIdentifier("CUSTOM"))
        let node = M1PreampNode(
            id: id,
            isEnabled: true,
            gainDB: 6.5,
            channels: .identifiers([left, unresolved])
        )

        XCTAssertEqual(node.id, id)
        XCTAssertTrue(node.isEnabled)
        XCTAssertEqual(node.gainDB, 6.5)
        XCTAssertEqual(node.channels, .identifiers([left, unresolved]))

        let disabledAll = M1PreampNode(
            id: UUID(),
            isEnabled: false,
            gainDB: 0,
            channels: .all
        )
        XCTAssertFalse(disabledAll.isEnabled)
        XCTAssertEqual(disabledAll.channels, .all)
    }

    func testLayoutPreservesRealtimeBufferAddresses() throws {
        let snapshot = try XCTUnwrap(
            M1OutputLayoutSnapshot(
                sampleRate: 48_000,
                maximumFrameCount: 512,
                bufferChannelCounts: [2, 1],
                semanticPositionsByChannelIndex: [.left, .right, .lowFrequencyEffects]
            )
        )

        XCTAssertEqual(snapshot.bufferChannelCounts, [2, 1])
        XCTAssertEqual(
            snapshot.channels,
            [
                M1OutputChannel(
                    linearIndex: 0,
                    bufferIndex: 0,
                    channelIndexInBuffer: 0,
                    identifier: try XCTUnwrap(M1ChannelIdentifier("L"))
                ),
                M1OutputChannel(
                    linearIndex: 1,
                    bufferIndex: 0,
                    channelIndexInBuffer: 1,
                    identifier: try XCTUnwrap(M1ChannelIdentifier("R"))
                ),
                M1OutputChannel(
                    linearIndex: 2,
                    bufferIndex: 1,
                    channelIndexInBuffer: 0,
                    identifier: try XCTUnwrap(M1ChannelIdentifier("LFE"))
                ),
            ]
        )
    }

    func testUnknownStereoLayoutUsesNumericFallbackWithoutGuessing() throws {
        let snapshot = try XCTUnwrap(
            M1OutputLayoutSnapshot(
                sampleRate: 44_100,
                maximumFrameCount: 256,
                bufferChannelCounts: [2],
                semanticPositionsByChannelIndex: [nil, nil]
            )
        )

        XCTAssertEqual(snapshot.channels.map(\.identifier.rawValue), ["1", "2"])
    }

    func testMissingSemanticPositionFallsBackOnlyAtThatRealtimeIndex() throws {
        let snapshot = try XCTUnwrap(
            M1OutputLayoutSnapshot(
                sampleRate: 48_000,
                maximumFrameCount: 256,
                bufferChannelCounts: [1, 2],
                semanticPositionsByChannelIndex: [.left, nil, .right]
            )
        )

        XCTAssertEqual(snapshot.channels.map(\.identifier.rawValue), ["L", "2", "R"])
        XCTAssertEqual(snapshot.channels.map(\.bufferIndex), [0, 1, 1])
        XCTAssertEqual(snapshot.channels.map(\.channelIndexInBuffer), [0, 0, 1])
    }

    func testDuplicateSemanticPositionsUseUnambiguousNumericFallback() throws {
        let snapshot = try XCTUnwrap(
            M1OutputLayoutSnapshot(
                sampleRate: 48_000,
                maximumFrameCount: 128,
                bufferChannelCounts: [1, 1],
                semanticPositionsByChannelIndex: [.left, .left]
            )
        )

        XCTAssertEqual(snapshot.channels.map(\.identifier.rawValue), ["1", "2"])
    }

    func testDuplicatePositionsDoNotDiscardOtherUniqueSemanticLabels() throws {
        let snapshot = try XCTUnwrap(
            M1OutputLayoutSnapshot(
                sampleRate: 48_000,
                maximumFrameCount: 128,
                bufferChannelCounts: [3],
                semanticPositionsByChannelIndex: [.left, .left, .right]
            )
        )

        XCTAssertEqual(snapshot.channels.map(\.identifier.rawValue), ["1", "2", "R"])
    }

    func testGraphicEQCSVMatchesEqualizerAPONumericPairParsing() throws {
        let points = try M1GraphicEQCSVCodec.decode([
            "* ignored 30 4\n1000,5; -2,5\n2000 3 trailing-value 99",
            "20\t-1\n20000 2\n",
        ])
        XCTAssertEqual(points, [
            M1GraphicEQPoint(frequencyHz: 20, gainDB: -1),
            M1GraphicEQPoint(frequencyHz: 1_000.5, gainDB: -2.5),
            M1GraphicEQPoint(frequencyHz: 2_000, gainDB: 3),
            M1GraphicEQPoint(frequencyHz: 20_000, gainDB: 2),
        ])
        XCTAssertEqual(
            M1GraphicEQCSVCodec.encode(Array(points.prefix(2))),
            "20.0\t-1.0\n1000.5\t-2.5\n"
        )
    }

    func testGraphicEQCSVPreservesPositiveOutOfProcessingRangePoints() throws {
        XCTAssertEqual(
            try M1GraphicEQCSVCodec.decode(["10 -1\n20000.1 2\n200000 3"]),
            [
                M1GraphicEQPoint(frequencyHz: 10, gainDB: -1),
                M1GraphicEQPoint(frequencyHz: 20_000.1, gainDB: 2),
                M1GraphicEQPoint(frequencyHz: 200_000, gainDB: 3),
            ]
        )
    }

    func testGraphicEQCSVRejectsDuplicateAndNonPositivePoints() {
        XCTAssertThrowsError(try M1GraphicEQCSVCodec.decode(["20 0\n20 1"])) {
            XCTAssertEqual($0 as? M1GraphicEQCSVCodecError, .invalidPoints)
        }
        XCTAssertThrowsError(try M1GraphicEQCSVCodec.decode(["0 0"])) {
            XCTAssertEqual($0 as? M1GraphicEQCSVCodecError, .invalidPoints)
        }
        XCTAssertThrowsError(try M1GraphicEQCSVCodec.decode(["-1 0"])) {
            XCTAssertEqual($0 as? M1GraphicEQCSVCodecError, .invalidPoints)
        }
    }

    func testLayoutRejectsInvalidOrMismatchedTopology() {
        XCTAssertNil(
            M1OutputLayoutSnapshot(
                sampleRate: .nan,
                maximumFrameCount: 128,
                bufferChannelCounts: [2],
                semanticPositionsByChannelIndex: [nil, nil]
            )
        )
        XCTAssertNil(
            M1OutputLayoutSnapshot(
                sampleRate: .infinity,
                maximumFrameCount: 128,
                bufferChannelCounts: [2],
                semanticPositionsByChannelIndex: [nil, nil]
            )
        )
        XCTAssertNil(
            M1OutputLayoutSnapshot(
                sampleRate: 0,
                maximumFrameCount: 128,
                bufferChannelCounts: [2],
                semanticPositionsByChannelIndex: [nil, nil]
            )
        )
        XCTAssertNil(
            M1OutputLayoutSnapshot(
                sampleRate: 48_000,
                maximumFrameCount: 0,
                bufferChannelCounts: [2],
                semanticPositionsByChannelIndex: [nil, nil]
            )
        )
        XCTAssertNil(
            M1OutputLayoutSnapshot(
                sampleRate: 48_000,
                maximumFrameCount: -1,
                bufferChannelCounts: [2],
                semanticPositionsByChannelIndex: [nil, nil]
            )
        )
        XCTAssertNil(
            M1OutputLayoutSnapshot(
                sampleRate: 48_000,
                maximumFrameCount: 128,
                bufferChannelCounts: [],
                semanticPositionsByChannelIndex: []
            )
        )
        XCTAssertNil(
            M1OutputLayoutSnapshot(
                sampleRate: 48_000,
                maximumFrameCount: 128,
                bufferChannelCounts: [0],
                semanticPositionsByChannelIndex: []
            )
        )
        XCTAssertNil(
            M1OutputLayoutSnapshot(
                sampleRate: 48_000,
                maximumFrameCount: 128,
                bufferChannelCounts: [-1],
                semanticPositionsByChannelIndex: []
            )
        )
        XCTAssertNil(
            M1OutputLayoutSnapshot(
                sampleRate: 48_000,
                maximumFrameCount: 128,
                bufferChannelCounts: [2],
                semanticPositionsByChannelIndex: [nil]
            )
        )
        XCTAssertNil(
            M1OutputLayoutSnapshot(
                sampleRate: 48_000,
                maximumFrameCount: 128,
                bufferChannelCounts: [1],
                semanticPositionsByChannelIndex: [nil, nil]
            )
        )
    }
}
