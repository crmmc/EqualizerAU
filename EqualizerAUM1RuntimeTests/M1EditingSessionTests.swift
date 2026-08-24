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

    func testSpaceSelectionAddsOrTogglesFocusedNode() {
        var session = M1EditingSession(nodes: nodes(4))
        session.select(ids[0], mode: .replacing)
        session.moveFocus(by: 2, extending: false)

        session.selectFocused(toggling: false)
        XCTAssertEqual(session.orderedSelection, [ids[0], ids[2]])
        session.selectFocused(toggling: false)
        XCTAssertEqual(session.orderedSelection, [ids[0], ids[2]])

        session.selectFocused(toggling: true)
        XCTAssertEqual(session.orderedSelection, [ids[0]])
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

    func testDragFromUnselectedNodeAtomicallyReplacesSelectionBeforeMove() throws {
        var session = M1EditingSession(nodes: nodes(4))
        session.select(ids[0], mode: .replacing)
        session.select(ids[2], mode: .toggling)

        try session.moveDragSelection(
            startingAt: ids[1],
            to: 4,
            operation: .move,
            copiedIDs: [],
            effectsEnabled: true
        )

        XCTAssertEqual(session.nodes.map(\.id), [ids[0], ids[2], ids[3], ids[1]])
        XCTAssertEqual(session.orderedSelection, [ids[1]])
        XCTAssertEqual(session.focusedNodeID, ids[1])
    }

    func testDragFromSelectedNodeMovesWholeSelection() throws {
        var session = M1EditingSession(nodes: nodes(5))
        session.select(ids[1], mode: .replacing)
        session.select(ids[3], mode: .toggling)

        try session.moveDragSelection(
            startingAt: ids[3],
            to: 5,
            operation: .move,
            copiedIDs: [],
            effectsEnabled: true
        )

        XCTAssertEqual(session.nodes.map(\.id), [ids[0], ids[2], ids[4], ids[1], ids[3]])
        XCTAssertEqual(session.orderedSelection, [ids[1], ids[3]])
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
        let unsupported = Data("{\"nodes\":[],\"schemaVersion\":9}\n".utf8)
        XCTAssertThrowsError(try M1NodeEnvelopeCodec.decode(unsupported)) {
            XCTAssertEqual($0 as? M1EditingSessionError, .unsupportedClipboardSchema(9))
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
            isEnabled: false,
            selection: .identifiers([M1ChannelIdentifier("L")!])
        )
        let preamp = M1PreampNode(id: ids[1], isEnabled: true, gainDB: -3, channels: .all)
        let envelope = try M1NodeEnvelopeCodec.encode([channels, preamp])
        let decoded = try M1NodeEnvelopeCodec.decode(envelope.data)
        XCTAssertEqual(decoded.nodes.map(\.kind), [.channels, .preamp])
        XCTAssertFalse(decoded.nodes[0].isEnabled)

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
        XCTAssertFalse(session.nodes[2].isEnabled)
    }

    func testNodeKindSpecificEditsRejectWrongNodeKinds() throws {
        let channels = M1ProcessingNode.channels(id: ids[0], selection: .all)
        let preamp = M1PreampNode(id: ids[1], isEnabled: true, gainDB: 0, channels: .all)
        var session = M1EditingSession(nodes: [channels, preamp])

        XCTAssertThrowsError(try session.setGainDB(id: channels.id, gainDB: 2, effectsEnabled: true)) {
            XCTAssertEqual($0 as? M1EditingSessionError, .invalidNodeKind)
        }
        try session.setNodeEnabled(id: channels.id, enabled: false, effectsEnabled: true)
        XCTAssertFalse(session.nodes[0].isEnabled)
        try session.undo(effectsEnabled: true)
        XCTAssertTrue(session.nodes[0].isEnabled)
        try session.redo(effectsEnabled: true)
        XCTAssertFalse(session.nodes[0].isEnabled)
        XCTAssertThrowsError(try session.setChannels(id: preamp.id, channels: .all, effectsEnabled: true)) {
            XCTAssertEqual($0 as? M1EditingSessionError, .invalidNodeKind)
        }
        var disabledChannels = channels
        disabledChannels.isEnabled = false
        XCTAssertEqual(session.nodes, [disabledChannels, preamp])
    }

    func testGraphicEQClipboardCopyPreservesTypedPoints() throws {
        var points = M1GraphicEQContract.legacyFlatPoints
        points[5].gainDB = -3
        let eq = M1ProcessingNode.graphicEQ(id: ids[0], points: points)
        let envelope = try M1NodeEnvelopeCodec.encode([eq])
        let decoded = try XCTUnwrap(M1NodeEnvelopeCodec.decode(envelope.data).nodes.first)
        XCTAssertEqual(decoded, eq)

        var session = M1EditingSession(nodes: [decoded])
        XCTAssertThrowsError(
            try session.setGainDB(id: ids[0], gainDB: 1, effectsEnabled: true)
        )
    }

    func testGraphicEQPointPasteAssignsIdentityAndRoundTripsUndoRedo() throws {
        let source = M1ProcessingNode.graphicEQ(
            id: ids[0],
            points: [
                M1GraphicEQPoint(frequencyHz: 20, gainDB: -3),
                M1GraphicEQPoint(frequencyHz: 20_000, gainDB: 6),
            ]
        )
        let pastedID = ids[1]
        var session = M1EditingSession(nodes: [])
        try session.paste([source], newIDs: [pastedID], effectsEnabled: true)

        XCTAssertEqual(session.nodes.map(\.id), [pastedID])
        XCTAssertEqual(session.nodes[0].graphicEQPoints, source.graphicEQPoints)
        XCTAssertEqual(session.historyMetrics.undoCount, 1)
        try session.undo(effectsEnabled: true)
        XCTAssertTrue(session.nodes.isEmpty)
        try session.redo(effectsEnabled: true)
        XCTAssertEqual(session.nodes.map(\.id), [pastedID])
        XCTAssertEqual(session.nodes[0].graphicEQPoints, source.graphicEQPoints)
    }

    func testGraphicEQWholePointsCommitIsOneValidatedHistoryStep() throws {
        let originalPoints = [
            M1GraphicEQPoint(frequencyHz: 20, gainDB: -3),
            M1GraphicEQPoint(frequencyHz: 200, gainDB: 1),
        ]
        var session = M1EditingSession(nodes: [.graphicEQ(id: ids[0], points: originalPoints)])
        let replacement = [
            M1GraphicEQPoint(frequencyHz: 20, gainDB: -3),
            M1GraphicEQPoint(frequencyHz: 2_000, gainDB: 5.06),
            M1GraphicEQPoint(frequencyHz: 20_000, gainDB: -1.2),
        ]

        try session.setGraphicEQPoints(id: ids[0], points: replacement, effectsEnabled: true)

        XCTAssertEqual(session.historyMetrics.undoCount, 1)
        XCTAssertEqual(session.nodes[0].graphicEQPoints, replacement)
        try session.undo(effectsEnabled: true)
        XCTAssertEqual(session.nodes[0].graphicEQPoints, originalPoints)
        try session.redo(effectsEnabled: true)
        XCTAssertEqual(session.nodes[0].graphicEQPoints, replacement)
        try session.undo(effectsEnabled: true)

        XCTAssertThrowsError(
            try session.setGraphicEQPoints(
                id: ids[0],
                points: [
                    M1GraphicEQPoint(frequencyHz: 20, gainDB: 0),
                    M1GraphicEQPoint(frequencyHz: 20, gainDB: 1),
                ],
                effectsEnabled: true
            )
        )
        XCTAssertEqual(session.nodes[0].graphicEQPoints, originalPoints)
    }

    func testClipboardDecodesVersionsOneThroughSixAndPreservesGraphicEQPoints() throws {
        let preampID = ids[0]
        let v1 = Data(
            "{\"schemaVersion\":1,\"nodes\":[{\"id\":\"\(preampID)\",\"type\":\"preamp\",\"isEnabled\":true,\"gainDB\":-2,\"channels\":\"all\"}]}".utf8
        )
        let v2 = Data(
            "{\"schemaVersion\":2,\"nodes\":[{\"id\":\"\(preampID)\",\"type\":\"preamp\",\"isEnabled\":true,\"gainDB\":-2}]}".utf8
        )
        let bands = M1GraphicEQContract.legacyFlatPoints.map {
            "{\"frequencyHz\":\($0.frequencyHz),\"gainDB\":\($0.gainDB)}"
        }.joined(separator: ",")
        let v3 = Data(
            "{\"schemaVersion\":3,\"nodes\":[{\"id\":\"\(ids[1])\",\"type\":\"graphicEQ\",\"isEnabled\":true,\"bands\":[\(bands)]}]}".utf8
        )
        let currentPoints = [
            "{\"frequencyHz\":20,\"gainDB\":-3}",
            "{\"frequencyHz\":2000,\"gainDB\":1.5}",
            "{\"frequencyHz\":30000,\"gainDB\":6}",
        ].joined(separator: ",")
        let v6 = Data(
            "{\"schemaVersion\":6,\"nodes\":[{\"id\":\"\(ids[4])\",\"type\":\"graphicEQ\",\"isEnabled\":true,\"points\":[\(currentPoints)]}]}".utf8
        )
        let legacyStorageID = ids[2]
        let v4 = Data(
            "{\"schemaVersion\":4,\"nodes\":[{\"id\":\"\(ids[3])\",\"type\":\"channels\",\"channels\":[\"L\"]}]}".utf8
        )
        let v5 = Data(
            "{\"schemaVersion\":5,\"nodes\":[{\"id\":\"\(ids[3])\",\"type\":\"convolution\",\"isEnabled\":true,\"ir\":{\"storageID\":\"\(legacyStorageID)\",\"originalFileName\":\"Room IR.wav\",\"sha256\":\"\(String(repeating: "a", count: 64))\",\"sampleRate\":48000,\"channelCount\":1,\"frameCount\":48000}}]}".utf8
        )

        XCTAssertEqual(try M1NodeEnvelopeCodec.decode(v1).nodes.map(\.kind), [.preamp])
        XCTAssertEqual(try M1NodeEnvelopeCodec.decode(v2).nodes.map(\.kind), [.preamp])
        let migratedV3 = try M1NodeEnvelopeCodec.decode(v3)
        XCTAssertEqual(migratedV3.nodes.map(\.kind), [.graphicEQ])
        XCTAssertEqual(
            try XCTUnwrap(migratedV3.nodes.first).graphicEQPoints,
            M1GraphicEQContract.legacyFlatPoints
        )
        for schemaVersion in 4...5 {
            let legacyGraphicEQ = Data(
                "{\"schemaVersion\":\(schemaVersion),\"nodes\":[{\"id\":\"\(ids[1])\","
                    .appending("\"type\":\"graphicEQ\",\"isEnabled\":true,\"bands\":[\(bands)]}]}\n")
                    .utf8
            )
            XCTAssertEqual(
                try XCTUnwrap(M1NodeEnvelopeCodec.decode(legacyGraphicEQ).nodes.first)
                    .graphicEQPoints,
                M1GraphicEQContract.legacyFlatPoints
            )
        }
        let migratedV4 = try M1NodeEnvelopeCodec.decode(v4)
        XCTAssertEqual(migratedV4.nodes.map(\.kind), [.channels])
        XCTAssertTrue(try XCTUnwrap(migratedV4.nodes.first).isEnabled)
        let migratedV5 = try M1NodeEnvelopeCodec.decode(v5)
        XCTAssertEqual(migratedV5.nodes.map(\.kind), [.convolution])
        XCTAssertEqual(
            migratedV5.nodes.first?.convolutionIR,
            M1ConvolutionIRStore.legacyReference(storageID: legacyStorageID)
        )
        for schemaVersion in 4...7 {
            let legacyConvolution = Data(
                "{\"schemaVersion\":\(schemaVersion),\"nodes\":[{\"id\":\"\(ids[3])\",\"type\":\"convolution\",\"isEnabled\":true,\"ir\":{\"storageID\":\"\(legacyStorageID)\",\"originalFileName\":\"Room IR.wav\",\"sha256\":\"\(String(repeating: "a", count: 64))\",\"sampleRate\":48000,\"channelCount\":1,\"frameCount\":48000}}]}".utf8
            )
            let migrated = try M1NodeEnvelopeCodec.decode(legacyConvolution)
            XCTAssertEqual(
                migrated.nodes.first?.convolutionIR,
                M1ConvolutionIRStore.legacyReference(storageID: legacyStorageID)
            )
            let canonical = String(decoding: migrated.data, as: UTF8.self)
            XCTAssertTrue(canonical.contains("\"schemaVersion\" : 8"))
            XCTAssertFalse(canonical.contains("\"storageID\""))
        }
        let decodedV6 = try M1NodeEnvelopeCodec.decode(v6)
        XCTAssertEqual(decodedV6.nodes.map(\.kind), [.graphicEQ])
        XCTAssertEqual(
            try XCTUnwrap(decodedV6.nodes.first).graphicEQPoints,
            [
                M1GraphicEQPoint(frequencyHz: 20, gainDB: -3),
                M1GraphicEQPoint(frequencyHz: 2_000, gainDB: 1.5),
                M1GraphicEQPoint(frequencyHz: 30_000, gainDB: 6),
            ]
        )
        XCTAssertTrue(String(decoding: decodedV6.data, as: UTF8.self)
            .contains("\"schemaVersion\" : 8"))
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
        XCTAssertEqual(session.nodes[1].convolutionIR?.sourcePath, source.convolutionIR?.sourcePath)
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

    func testReplaceSelectionFiltersUnknownIDsAndPinsFocusToFirstSelected() {
        var session = M1EditingSession(nodes: nodes(4))
        session.select(ids[2], mode: .replacing)

        session.replaceSelection([UUID(), ids[1], ids[3]])

        XCTAssertEqual(session.orderedSelection, [ids[1], ids[3]])
        XCTAssertEqual(session.focusedNodeID, ids[1])
        XCTAssertEqual(session.selectionAnchorNodeID, ids[1])

        session.replaceSelection([UUID()])

        XCTAssertTrue(session.selectedNodeIDs.isEmpty)
        XCTAssertEqual(session.focusedNodeID, ids[1])
    }

    func testSelectNilClearsSelectionAndUnknownIDIsNoOp() {
        var session = M1EditingSession(nodes: nodes(3))
        session.select(ids[1], mode: .replacing)

        session.select(nil, mode: .replacing)
        XCTAssertTrue(session.selectedNodeIDs.isEmpty)
        XCTAssertEqual(session.focusedNodeID, ids[1])

        session.select(UUID(), mode: .replacing)
        XCTAssertTrue(session.selectedNodeIDs.isEmpty)
        XCTAssertEqual(session.focusedNodeID, ids[1])
    }

    func testClearedFocusRestoresViaSelectAllAndExtensionUsesFocusAsAnchor() throws {
        var selectingAll = M1EditingSession(nodes: nodes(3))
        selectingAll.selectAll()
        try selectingAll.deleteSelection(effectsEnabled: true)
        XCTAssertNil(selectingAll.focusedNodeID)
        try selectingAll.addPreamp(before: nil, nodeID: ids[0], effectsEnabled: true)
        try selectingAll.addPreamp(before: nil, nodeID: ids[1], effectsEnabled: true)
        XCTAssertNil(selectingAll.focusedNodeID)

        selectingAll.selectAll()

        XCTAssertEqual(selectingAll.orderedSelection, [ids[0], ids[1]])
        XCTAssertEqual(selectingAll.focusedNodeID, ids[0])
        XCTAssertEqual(selectingAll.selectionAnchorNodeID, ids[0])

        var extending = M1EditingSession(nodes: nodes(3))
        extending.selectAll()
        try extending.deleteSelection(effectsEnabled: true)
        try extending.addPreamp(before: nil, nodeID: ids[0], effectsEnabled: true)
        try extending.addPreamp(before: nil, nodeID: ids[1], effectsEnabled: true)

        extending.select(ids[1], mode: .extending)

        XCTAssertEqual(extending.orderedSelection, [ids[1]])
        XCTAssertEqual(extending.focusedNodeID, ids[1])
    }

    func testMoveFocusClampsToNodeRangeAndIgnoresEmptySessions() throws {
        var session = M1EditingSession(nodes: nodes(3))
        session.moveFocus(by: 99, extending: false)
        XCTAssertEqual(session.focusedNodeID, ids[2])
        session.moveFocus(by: -99, extending: false)
        XCTAssertEqual(session.focusedNodeID, ids[0])

        var cleared = M1EditingSession(nodes: nodes(3))
        cleared.selectAll()
        try cleared.deleteSelection(effectsEnabled: true)
        try cleared.addPreamp(before: nil, nodeID: ids[0], effectsEnabled: true)
        cleared.moveFocus(by: -99, extending: false)
        XCTAssertEqual(cleared.focusedNodeID, ids[0])

        var empty = M1EditingSession(nodes: [])
        empty.moveFocus(by: 1, extending: true)
        XCTAssertTrue(empty.nodes.isEmpty)
    }

    func testDeleteNodeRejectsUnknownID() throws {
        var session = M1EditingSession(nodes: nodes(2))
        XCTAssertThrowsError(try session.deleteNode(id: UUID(), effectsEnabled: true)) {
            XCTAssertEqual($0 as? M1EditingSessionError, .nodeNotFound)
        }
        XCTAssertEqual(session.nodes.count, 2)
    }

    func testAddGraphicEQInsertsBeforeAnchorAndAppendsWithoutAnchor() throws {
        var session = M1EditingSession(nodes: nodes(2))
        try session.addGraphicEQ(before: ids[1], nodeID: ids[2], effectsEnabled: true)
        XCTAssertEqual(session.nodes.map(\.kind), [.preamp, .graphicEQ, .preamp])
        try session.addGraphicEQ(before: nil, nodeID: ids[3], effectsEnabled: true)
        XCTAssertEqual(session.nodes.map(\.kind), [.preamp, .graphicEQ, .preamp, .graphicEQ])
    }

    func testClipboardEncodeRejectsOversizedNodeList() {
        let many = (0..<35_000).map { index in
            M1PreampNode(
                id: UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", index))!,
                isEnabled: true,
                gainDB: 0,
                channels: .all
            )
        }
        XCTAssertThrowsError(try M1NodeEnvelopeCodec.encode(many)) {
            if case .clipboardTooLarge = $0 as? M1EditingSessionError {} else {
                XCTFail("expected clipboardTooLarge, got \($0)")
            }
        }
    }

    private func convolutionIR(
        storageID: UUID,
        fileName: String = "Room IR.wav"
    ) -> M1ConvolutionIRReference {
        M1ConvolutionIRReference(
            sourcePath: "/tmp/\(storageID.uuidString)-\(fileName)"
        )
    }

    private func nodes(_ count: Int) -> [M1PreampNode] {
        (0..<count).map {
            M1PreampNode(id: ids[$0], isEnabled: true, gainDB: 0, channels: .all)
        }
    }
}
