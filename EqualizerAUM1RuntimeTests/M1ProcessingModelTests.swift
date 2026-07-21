import XCTest

final class M1ProcessingModelTests: XCTestCase {
    func testGraphicEQFactoryUsesFixedReferenceBandsAndCopiesPayload() {
        var node = M1ProcessingNode.graphicEQ(id: UUID())
        node.graphicEQBands[7].gainDB = 3.5
        let copy = node.copied(id: UUID())

        XCTAssertEqual(node.graphicEQBands.map(\.frequencyHz), M1GraphicEQContract.centerFrequenciesHz)
        XCTAssertEqual(copy.kind, .graphicEQ)
        XCTAssertNotEqual(copy.id, node.id)
        XCTAssertEqual(copy.graphicEQBands, node.graphicEQBands)
        XCTAssertEqual(M1GraphicEQContract.gainStepDB, 0.1)
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
