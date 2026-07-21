import Foundation
import XCTest

final class M1EditingSessionTests: XCTestCase {
    private let ids = (1...6).map {
        UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", $0))!
    }

    func testInitialFocusDoesNotSelectFirstNode() {
        let session = M1EditingSession(nodes: nodes(4))
        XCTAssertEqual(session.focusedNodeID, ids[0])
        XCTAssertTrue(session.selectedNodeIDs.isEmpty)
    }

    func testReplacingTogglingAndBidirectionalRangeSelection() {
        var session = M1EditingSession(nodes: nodes(5))
        session.select(ids[1], mode: .replacing)
        session.select(ids[4], mode: .extending)
        XCTAssertEqual(session.orderedSelection, Array(ids[1...4]))
        session.select(ids[2], mode: .toggling)
        XCTAssertEqual(session.orderedSelection, [ids[1], ids[3], ids[4]])
        session.select(ids[0], mode: .extending)
        XCTAssertEqual(session.orderedSelection, Array(ids[0...2]))
    }

    func testSelectAllAndKeyboardFocusExtension() {
        var session = M1EditingSession(nodes: nodes(4))
        session.moveFocus(by: 2, extending: false)
        XCTAssertEqual(session.focusedNodeID, ids[2])
        XCTAssertTrue(session.selectedNodeIDs.isEmpty)
        session.moveFocus(by: -2, extending: true)
        XCTAssertEqual(session.orderedSelection, Array(ids[0...2]))
        session.selectAll()
        XCTAssertEqual(session.orderedSelection, Array(ids[0...3]))
    }

    func testAddDoesNotChangeSelectionAndDeleteSelectionIsOneUndoStep() throws {
        var session = M1EditingSession(nodes: nodes(4))
        session.select(ids[1], mode: .replacing)
        try session.addPreamp(before: ids[1], nodeID: ids[4], effectsEnabled: true)
        XCTAssertEqual(session.orderedSelection, [ids[1]])
        session.select(ids[3], mode: .extending)
        try session.deleteSelection(effectsEnabled: true)
        XCTAssertEqual(session.nodes.map(\.id), [ids[0], ids[4]])
        try session.undo(effectsEnabled: true)
        XCTAssertEqual(session.nodes.map(\.id), [ids[0], ids[4], ids[1], ids[2], ids[3]])
    }

    func testPasteInsertsBeforeFirstSelectionWithNewIDsAndOneHistoryStep() throws {
        var session = M1EditingSession(nodes: nodes(3))
        session.select(ids[1], mode: .replacing)
        let pasted = [
            M1PreampNode(id: UUID(), isEnabled: false, gainDB: -3, channels: .all),
            M1PreampNode(id: UUID(), isEnabled: true, gainDB: 4, channels: .all),
        ]
        try session.paste(pasted, newIDs: [ids[3], ids[4]], effectsEnabled: true)
        XCTAssertEqual(session.nodes.map(\.id), [ids[0], ids[3], ids[4], ids[1], ids[2]])
        XCTAssertEqual(session.orderedSelection, [ids[3], ids[4]])
        XCTAssertEqual(session.focusedNodeID, ids[3])
        try session.undo(effectsEnabled: true)
        XCTAssertEqual(session.nodes.map(\.id), Array(ids[0...2]))
    }

    func testGroupMovePreservesRelativeOrderAndUUIDs() throws {
        var session = M1EditingSession(nodes: nodes(5))
        session.select(ids[1], mode: .replacing)
        session.select(ids[3], mode: .toggling)
        try session.moveSelection(to: 5, operation: .move, copiedIDs: [], effectsEnabled: true)
        XCTAssertEqual(session.nodes.map(\.id), [ids[0], ids[2], ids[4], ids[1], ids[3]])
        XCTAssertEqual(session.orderedSelection, [ids[1], ids[3]])
    }

    func testOptionCopyPreservesValuesAndCreatesNewSelection() throws {
        var original = nodes(3)
        original[0].gainDB = -7
        var session = M1EditingSession(nodes: original)
        session.select(ids[0], mode: .replacing)
        session.select(ids[2], mode: .toggling)
        try session.moveSelection(
            to: 1,
            operation: .copy,
            copiedIDs: [ids[3], ids[4]],
            effectsEnabled: true
        )
        XCTAssertEqual(session.nodes.map(\.id), [ids[0], ids[3], ids[4], ids[1], ids[2]])
        XCTAssertEqual(session.nodes[1].gainDB, -7)
        XCTAssertEqual(session.orderedSelection, [ids[3], ids[4]])
    }

    func testGestureCoalescesContinuousGainChangesIntoOneUndo() throws {
        var session = M1EditingSession(nodes: nodes(1))
        session.beginGesture(ids[0])
        try session.setGainDB(id: ids[0], gainDB: 1, effectsEnabled: true)
        try session.setGainDB(id: ids[0], gainDB: 2, effectsEnabled: true)
        try session.setGainDB(id: ids[0], gainDB: 3, effectsEnabled: true)
        session.endGesture(ids[0])
        XCTAssertEqual(session.historyMetrics.undoCount, 1)
        try session.undo(effectsEnabled: true)
        XCTAssertEqual(session.nodes[0].gainDB, 0)
    }

    func testUnrelatedEditEndsGainGestureAndUsesIndependentHistorySteps() throws {
        var session = M1EditingSession(nodes: nodes(2))
        session.beginGesture(ids[0])
        try session.setGainDB(id: ids[0], gainDB: 1, effectsEnabled: true)
        try session.setNodeEnabled(id: ids[1], enabled: false, effectsEnabled: true)
        try session.setGainDB(id: ids[0], gainDB: 2, effectsEnabled: true)

        XCTAssertEqual(session.historyMetrics.undoCount, 3)
        try session.undo(effectsEnabled: true)
        XCTAssertEqual(session.nodes[0].gainDB, 1)
        XCTAssertFalse(session.nodes[1].isEnabled)
        try session.undo(effectsEnabled: true)
        XCTAssertTrue(session.nodes[1].isEnabled)
    }

    func testRowMovePreservesExistingMultiSelection() throws {
        var session = M1EditingSession(nodes: nodes(4))
        session.select(ids[0], mode: .replacing)
        session.select(ids[2], mode: .toggling)

        try session.moveNode(id: ids[1], to: 3, effectsEnabled: true)

        XCTAssertEqual(session.nodes.map(\.id), [ids[0], ids[2], ids[3], ids[1]])
        XCTAssertEqual(session.orderedSelection, [ids[0], ids[2]])
    }

    func testNewEditClearsRedo() throws {
        var session = M1EditingSession(nodes: nodes(1))
        try session.setGainDB(id: ids[0], gainDB: 1, effectsEnabled: true)
        try session.undo(effectsEnabled: true)
        XCTAssertTrue(session.canRedo)
        try session.setGainDB(id: ids[0], gainDB: 2, effectsEnabled: true)
        XCTAssertFalse(session.canRedo)
    }

    func testHistoryCountEvictsGloballyOldestRecords() throws {
        var session = M1EditingSession(nodes: nodes(1), historyCountLimit: 3)
        for gain in 1...5 {
            try session.setGainDB(id: ids[0], gainDB: Double(gain), effectsEnabled: true)
        }
        XCTAssertEqual(session.historyMetrics.undoCount, 3)
        try session.undo(effectsEnabled: true)
        try session.undo(effectsEnabled: true)
        try session.undo(effectsEnabled: true)
        XCTAssertEqual(session.nodes[0].gainDB, 2)
    }

    func testHistoryDataBudgetEvictsWithoutTouchingCurrentDraft() throws {
        var session = M1EditingSession(
            nodes: nodes(1),
            historyCountLimit: 30,
            historyDataSizeLimit: 500
        )
        for gain in 1...8 {
            try session.setGainDB(id: ids[0], gainDB: Double(gain), effectsEnabled: true)
        }
        XCTAssertLessThanOrEqual(session.historyMetrics.dataSize, 500)
        XCTAssertEqual(session.nodes[0].gainDB, 8)
    }

    func testClipboardEnvelopeIsCanonicalAndRoundTripsOrderedNodes() throws {
        let encoded = try M1NodeEnvelopeCodec.encode(nodes(2))
        let text = try XCTUnwrap(String(data: encoded.data, encoding: .utf8))
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertFalse(text.hasSuffix("\n\n"))
        XCTAssertLessThan(text.range(of: "\"nodes\"")!.lowerBound,
                          text.range(of: "\"schemaVersion\"")!.lowerBound)
        XCTAssertEqual(try M1NodeEnvelopeCodec.decode(encoded.data).nodes.map(\.id), Array(ids[0...1]))
    }

    func testClipboardRejectsUnsupportedSchemaMalformedAndOversizedData() {
        let unsupported = Data("{\"nodes\":[],\"schemaVersion\":5}\n".utf8)
        XCTAssertThrowsError(try M1NodeEnvelopeCodec.decode(unsupported)) {
            XCTAssertEqual($0 as? M1EditingSessionError, .unsupportedClipboardSchema(5))
        }
        XCTAssertThrowsError(try M1NodeEnvelopeCodec.decode(Data("nope".utf8)))
        XCTAssertThrowsError(try M1NodeEnvelopeCodec.decode(Data(
            repeating: 0,
            count: M1NodeEnvelopeCodec.maximumDataSize + 1
        )))
        XCTAssertThrowsError(try M1NodeEnvelopeCodec.decode(Data(
            "{\"schemaVersion\":3,\"nodes\":[],\"future\":true}".utf8
        )))
        XCTAssertThrowsError(try M1NodeEnvelopeCodec.decode(Data(
            "{\"schemaVersion\":3,\"schemaVersion\":3,\"nodes\":[]}".utf8
        )))
    }

    func testChannelsNodeClipboardAndOptionCopyPreserveExplicitScope() throws {
        let channels = M1ProcessingNode.channels(
            id: ids[0],
            selection: .identifiers([M1ChannelIdentifier("L")!])
        )
        let preamp = M1PreampNode(id: ids[1], isEnabled: true, gainDB: -3, channels: .all)
        let envelope = try M1NodeEnvelopeCodec.encode([channels, preamp])
        let decoded = try M1NodeEnvelopeCodec.decode(envelope.data)
        XCTAssertEqual(decoded.nodes.map(\.kind), [.channels, .preamp])

        var session = M1EditingSession(nodes: decoded.nodes)
        session.selectAll()
        try session.moveSelection(
            to: 2,
            operation: .copy,
            copiedIDs: [ids[2], ids[3]],
            effectsEnabled: true
        )
        XCTAssertEqual(session.nodes.map(\.kind), [.channels, .preamp, .channels, .preamp])
        XCTAssertEqual(session.nodes[2].channels, channels.channels)
    }

    func testNodeKindSpecificEditsRejectWrongNodeKinds() throws {
        let channels = M1ProcessingNode.channels(id: ids[0], selection: .all)
        let preamp = M1PreampNode(id: ids[1], isEnabled: true, gainDB: 0, channels: .all)
        var session = M1EditingSession(nodes: [channels, preamp])

        XCTAssertThrowsError(try session.setGainDB(id: channels.id, gainDB: 2, effectsEnabled: true)) {
            XCTAssertEqual($0 as? M1EditingSessionError, .invalidNodeKind)
        }
        XCTAssertThrowsError(try session.setNodeEnabled(id: channels.id, enabled: false, effectsEnabled: true)) {
            XCTAssertEqual($0 as? M1EditingSessionError, .invalidNodeKind)
        }
        XCTAssertThrowsError(try session.setChannels(id: preamp.id, channels: .all, effectsEnabled: true)) {
            XCTAssertEqual($0 as? M1EditingSessionError, .invalidNodeKind)
        }
        XCTAssertEqual(session.nodes, [channels, preamp])
    }

    func testGraphicEQClipboardCopyAndGesturePreserveTypedBands() throws {
        var eq = M1ProcessingNode.graphicEQ(id: ids[0])
        eq.graphicEQBands[5].gainDB = -3
        let envelope = try M1NodeEnvelopeCodec.encode([eq])
        let decoded = try XCTUnwrap(M1NodeEnvelopeCodec.decode(envelope.data).nodes.first)
        XCTAssertEqual(decoded, eq)

        var session = M1EditingSession(nodes: [decoded])
        session.beginGesture(ids[0])
        try session.setGraphicEQGainDB(id: ids[0], bandIndex: 5, gainDB: -2.04, effectsEnabled: true)
        try session.setGraphicEQGainDB(id: ids[0], bandIndex: 5, gainDB: -1.04, effectsEnabled: true)
        session.endGesture(ids[0])
        XCTAssertEqual(session.historyMetrics.undoCount, 1)
        XCTAssertEqual(session.nodes[0].graphicEQBands[5].gainDB, -1, accuracy: 1e-12)
        try session.undo(effectsEnabled: true)
        XCTAssertEqual(session.nodes[0].graphicEQBands[5].gainDB, -3)

        XCTAssertThrowsError(
            try session.setGainDB(id: ids[0], gainDB: 1, effectsEnabled: true)
        )
    }

    func testClipboardDecodesVersionsOneThroughFourAndPreservesVersionThreeGraphicEQ() throws {
        let preampID = ids[0]
        let v1 = Data(
            "{\"schemaVersion\":1,\"nodes\":[{\"id\":\"\(preampID)\",\"type\":\"preamp\",\"isEnabled\":true,\"gainDB\":-2,\"channels\":\"all\"}]}".utf8
        )
        let v2 = Data(
            "{\"schemaVersion\":2,\"nodes\":[{\"id\":\"\(preampID)\",\"type\":\"preamp\",\"isEnabled\":true,\"gainDB\":-2}]}".utf8
        )
        let bands = M1GraphicEQContract.flatBands.map {
            "{\"frequencyHz\":\($0.frequencyHz),\"gainDB\":\($0.gainDB)}"
        }.joined(separator: ",")
        let v3 = Data(
            "{\"schemaVersion\":3,\"nodes\":[{\"id\":\"\(ids[1])\",\"type\":\"graphicEQ\",\"isEnabled\":true,\"bands\":[\(bands)]}]}".utf8
        )
        let ir = convolutionIR(storageID: ids[2])
        let v4 = try M1NodeEnvelopeCodec.encode([.convolution(id: ids[3], ir: ir)]).data

        XCTAssertEqual(try M1NodeEnvelopeCodec.decode(v1).nodes.map(\.kind), [.preamp])
        XCTAssertEqual(try M1NodeEnvelopeCodec.decode(v2).nodes.map(\.kind), [.preamp])
        XCTAssertEqual(try M1NodeEnvelopeCodec.decode(v3).nodes.map(\.kind), [.graphicEQ])
        XCTAssertEqual(try M1NodeEnvelopeCodec.decode(v4).nodes.map(\.kind), [.convolution])
        XCTAssertTrue(String(decoding: try M1NodeEnvelopeCodec.decode(v3).data, as: UTF8.self)
            .contains("\"schemaVersion\" : 4"))
    }

    func testConvolutionClipboardRoundTripAndCopyPreserveImmutableIRWithNewNodeIdentity() throws {
        let ir = convolutionIR(storageID: ids[5])
        let source = M1ProcessingNode.convolution(id: ids[0], isEnabled: false, ir: ir)
        let encoded = try M1NodeEnvelopeCodec.encode([source])
        let decoded = try XCTUnwrap(M1NodeEnvelopeCodec.decode(encoded.data).nodes.first)
        XCTAssertEqual(decoded, source)

        var session = M1EditingSession(nodes: [decoded])
        session.select(decoded.id, mode: .replacing)
        try session.moveSelection(
            to: 1,
            operation: .copy,
            copiedIDs: [ids[1]],
            effectsEnabled: true
        )
        XCTAssertEqual(session.nodes.map(\.id), [ids[0], ids[1]])
        XCTAssertEqual(session.nodes[1].convolutionIR, ir)
        XCTAssertEqual(session.nodes[1].convolutionIR?.storageID, source.convolutionIR?.storageID)
    }

    func testConvolutionAddReplaceEnableAndWrongKindContracts() throws {
        let firstIR = convolutionIR(storageID: ids[4])
        let secondIR = convolutionIR(storageID: ids[5], fileName: "replacement.wav")
        var session = M1EditingSession(nodes: nodes(1))

        try session.addConvolution(
            before: ids[0],
            nodeID: ids[1],
            ir: firstIR,
            effectsEnabled: true
        )
        XCTAssertEqual(session.nodes.map(\.kind), [.convolution, .preamp])
        try session.setConvolutionIR(id: ids[1], ir: secondIR, effectsEnabled: true)
        XCTAssertEqual(session.nodes[0].convolutionIR, secondIR)
        XCTAssertEqual(session.historyMetrics.undoCount, 2)
        try session.undo(effectsEnabled: true)
        XCTAssertEqual(session.nodes[0].convolutionIR, firstIR)

        try session.setNodeEnabled(id: ids[1], enabled: false, effectsEnabled: true)
        XCTAssertFalse(session.nodes[0].isEnabled)
        XCTAssertThrowsError(
            try session.setConvolutionIR(id: ids[0], ir: secondIR, effectsEnabled: true)
        ) {
            XCTAssertEqual($0 as? M1EditingSessionError, .invalidNodeKind)
        }
    }

    func testConvolutionClipboardRejectsUnknownNestedField() {
        let ir = "\"storageID\":\"\(ids[1])\",\"originalFileName\":\"ir.wav\",\"sha256\":\"\(String(repeating: "a", count: 64))\",\"sampleRate\":48000,\"channelCount\":1,\"frameCount\":1,\"future\":true"
        let data = Data(
            "{\"schemaVersion\":4,\"nodes\":[{\"id\":\"\(ids[0])\",\"type\":\"convolution\",\"isEnabled\":true,\"ir\":{\(ir)}}]}".utf8
        )
        XCTAssertThrowsError(try M1NodeEnvelopeCodec.decode(data))
    }

    private func convolutionIR(
        storageID: UUID,
        fileName: String = "Room IR.wav"
    ) -> M1ConvolutionIRReference {
        M1ConvolutionIRReference(
            storageID: storageID,
            originalFileName: fileName,
            sha256: String(repeating: "a", count: 64),
            sampleRate: 48_000,
            channelCount: 1,
            frameCount: 48_000
        )
    }

    private func nodes(_ count: Int) -> [M1PreampNode] {
        (0..<count).map {
            M1PreampNode(id: ids[$0], isEnabled: true, gainDB: 0, channels: .all)
        }
    }
}
