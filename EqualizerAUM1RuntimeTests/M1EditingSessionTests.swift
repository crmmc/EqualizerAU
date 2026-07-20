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
        let unsupported = Data("{\"nodes\":[],\"schemaVersion\":3}\n".utf8)
        XCTAssertThrowsError(try M1NodeEnvelopeCodec.decode(unsupported)) {
            XCTAssertEqual($0 as? M1EditingSessionError, .unsupportedClipboardSchema(3))
        }
        XCTAssertThrowsError(try M1NodeEnvelopeCodec.decode(Data("nope".utf8)))
        XCTAssertThrowsError(try M1NodeEnvelopeCodec.decode(Data(
            repeating: 0,
            count: M1NodeEnvelopeCodec.maximumDataSize + 1
        )))
        XCTAssertThrowsError(try M1NodeEnvelopeCodec.decode(Data(
            "{\"schemaVersion\":2,\"nodes\":[],\"future\":true}".utf8
        )))
        XCTAssertThrowsError(try M1NodeEnvelopeCodec.decode(Data(
            "{\"schemaVersion\":2,\"schemaVersion\":2,\"nodes\":[]}".utf8
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

    private func nodes(_ count: Int) -> [M1PreampNode] {
        (0..<count).map {
            M1PreampNode(id: ids[$0], isEnabled: true, gainDB: 0, channels: .all)
        }
    }
}
