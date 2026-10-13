import Foundation
import XCTest

final class M1FilterEditingTests: XCTestCase {
    // MARK: - Editing session

    func testAddFilterInsertsDefaultPeakingNode() throws {
        var session = M1EditingSession(nodes: [])
        try session.addFilter(before: nil, nodeID: testID, effectsEnabled: true)
        XCTAssertEqual(session.nodes.count, 1)
        let node = session.nodes[0]
        XCTAssertEqual(node.kind, .filter)
        XCTAssertEqual(node.id, testID)
        XCTAssertEqual(node.filterSpecification, .defaultSpecification())
        XCTAssertTrue(session.canUndo)
    }

    func testAddFilterInsertsBeforeExistingNodeWhenRequested() throws {
        var session = M1EditingSession(nodes: [])
        try session.addPreamp(before: nil, nodeID: otherID, effectsEnabled: true)
        try session.addFilter(before: otherID, nodeID: testID, effectsEnabled: true)
        XCTAssertEqual(session.nodes.map(\.kind), [.filter, .preamp])
        XCTAssertEqual(session.nodes[0].id, testID)
    }

    func testSetFilterSpecificationGuardsNodeKind() throws {
        var session = M1EditingSession(nodes: [])
        try session.addFilter(before: nil, nodeID: testID, effectsEnabled: true)
        let specification = M1FilterSpecification(
            type: .lowShelf,
            frequencyHz: 120,
            gainDB: 6,
            width: .slopeDBPerOctave(12),
            cornerFrequency: true
        )
        try session.setFilterSpecification(
            id: testID,
            specification: specification,
            effectsEnabled: true
        )
        XCTAssertEqual(session.nodes[0].filterSpecification, specification)

        try session.addPreamp(before: nil, nodeID: otherID, effectsEnabled: true)
        XCTAssertThrowsError(
            try session.setFilterSpecification(
                id: otherID,
                specification: specification,
                effectsEnabled: true
            )
        ) { error in
            XCTAssertEqual(
                error as? M1EditingSessionError,
                .invalidNodeKind
            )
        }
    }

    func testFilterParametersCoalesceDuringGesture() throws {
        var session = M1EditingSession(nodes: [])
        try session.addFilter(before: nil, nodeID: testID, effectsEnabled: true)
        session.beginGesture(testID)
        var specification = session.nodes[0].filterSpecification!
        specification.frequencyHz = 500
        try session.setFilterSpecification(
            id: testID,
            specification: specification,
            effectsEnabled: true
        )
        specification.frequencyHz = 750
        try session.setFilterSpecification(
            id: testID,
            specification: specification,
            effectsEnabled: true
        )
        session.endGesture(testID)
        XCTAssertEqual(session.historyMetrics.undoCount, 2)

        try session.undo(effectsEnabled: true)
        XCTAssertEqual(session.nodes[0].filterSpecification?.frequencyHz, 1_000)
    }

    func testFilterNodeCopiesRoundTripThroughSelectionEnvelope() throws {
        var session = M1EditingSession(nodes: [])
        try session.addFilter(before: nil, nodeID: testID, effectsEnabled: true)
        session.select(testID, mode: .replacing)
        let encoded = try session.encodedSelection()
        let decoded = try M1NodeEnvelopeCodec.decode(encoded!.data)
        XCTAssertEqual(decoded.nodes.count, 1)
        XCTAssertEqual(decoded.nodes[0].kind, .filter)
        XCTAssertEqual(
            decoded.nodes[0].filterSpecification,
            .defaultSpecification()
        )
    }

    func testPasteCreatesFilterNodesFromSpecifications() throws {
        var session = M1EditingSession(nodes: [])
        try session.addFilter(before: nil, nodeID: testID, effectsEnabled: true)
        session.select(testID, mode: .replacing)
        let specification = M1FilterSpecification(
            type: .highPass,
            frequencyHz: 30,
            gainDB: 0,
            width: .q(0.5),
            cornerFrequency: false
        )
        try session.paste([.filter(specification: specification)], newIDs: [otherID], effectsEnabled: true)
        XCTAssertEqual(session.nodes.count, 2)
        XCTAssertEqual(session.nodes[0].id, otherID)
        XCTAssertEqual(session.nodes[0].filterSpecification, specification)
        XCTAssertEqual(session.nodes[1].id, testID)
    }

    // MARK: - Configuration schema v9

    func testFilterNodeConfigurationRoundTripsThroughSchemaV9() throws {
        let specification = M1FilterSpecification(
            type: .lowShelf,
            frequencyHz: 120,
            gainDB: 6,
            width: .q(0.8),
            cornerFrequency: true
        )
        let snapshot = M1ConfigurationSnapshot(
            effectsEnabled: true,
            nodes: [.filter(specification: specification)]
        )
        let encoded = try M1ConfigurationCodec.encode(snapshot)
        XCTAssertEqual(encoded.snapshot.nodes[0].kind, .filter)
        XCTAssertEqual(encoded.snapshot.nodes[0].filterSpecification, specification)

        let wireJSON = String(decoding: encoded.data, as: UTF8.self)
        XCTAssertTrue(wireJSON.contains("\"type\" : \"filter\""))
        XCTAssertTrue(wireJSON.contains("\"cornerFrequency\" : true"))
    }

    func testSchemaV8ConfigurationStillDecodes() throws {
        let v8JSON = """
        {
          "schemaVersion": 8,
          "effectsEnabled": true,
          "nodes": [
            {"id": "\(testID.uuidString)", "type": "preamp", "isEnabled": true, "gainDB": -3},
            {"id": "\(otherID.uuidString)", "type": "graphicEQ", "isEnabled": true, "points": [
              {"frequencyHz": 100, "gainDB": 2}
            ]}
          ]
        }
        """
        let encoded = try M1ConfigurationCodec.decode(Data(v8JSON.utf8))
        XCTAssertEqual(encoded.snapshot.nodes.count, 2)
        XCTAssertEqual(encoded.snapshot.nodes[0].kind, .preamp)
        XCTAssertEqual(encoded.snapshot.nodes[0].gainDB, -3)
    }

    func testSchemaV8DocumentWithFilterNodeIsRejected() throws {
        let v8JSONWithFilter = """
        {
          "schemaVersion": 8,
          "effectsEnabled": true,
          "nodes": [
            {"id": "\(testID.uuidString)", "type": "filter", "isEnabled": true, "filter": {
              "type": "peaking", "frequencyHz": 100, "gainDB": 0,
              "width": {"kind": "q", "value": 1}, "cornerFrequency": false
            }}
          ]
        }
        """
        XCTAssertThrowsError(
            try M1ConfigurationCodec.decode(Data(v8JSONWithFilter.utf8))
        )
    }

    func testUnknownFilterTypeInV9DocumentIsRejected() throws {
        let json = """
        {
          "schemaVersion": 9,
          "effectsEnabled": true,
          "nodes": [
            {"id": "\(testID.uuidString)", "type": "filter", "isEnabled": true, "filter": {
              "type": "morphing", "frequencyHz": 100, "gainDB": 0,
              "width": {"kind": "q", "value": 1}, "cornerFrequency": false
            }}
          ]
        }
        """
        XCTAssertThrowsError(
            try M1ConfigurationCodec.decode(Data(json.utf8))
        )
    }

    func testFilterWidthKindsRoundTripThroughSchemaV9() throws {
        func encodedNodeJSON(
            type: String,
            widthKind: String,
            widthValue: String,
            corner: Bool
        ) -> String {
            """
            {
              "schemaVersion": 9,
              "effectsEnabled": true,
              "nodes": [
                {"id": "\(testID.uuidString)", "type": "filter", "isEnabled": true, "filter": {
                  "type": "\(type)", "frequencyHz": 100, "gainDB": 6,
                  "width": {"kind": "\(widthKind)", "value": \(widthValue)},
                  "cornerFrequency": \(corner)
                }}
              ]
            }
            """
        }
        let cases: [(String, String, String, Bool)] = [
            ("lowShelf", "q", "0.7", true),
            ("peaking", "bandwidthOctaves", "1.5", false),
            ("lowShelf", "slopeDBPerOctave", "10.8", true),
        ]
        for (type, kind, value, corner) in cases {
            let decoded = try M1ConfigurationCodec.decode(
                Data(encodedNodeJSON(type: type, widthKind: kind, widthValue: value, corner: corner).utf8)
            )
            let specification = try XCTUnwrap(decoded.snapshot.nodes[0].filterSpecification)
            switch kind {
            case "q":
                XCTAssertEqual(specification.width, .q(0.7))
            case "bandwidthOctaves":
                XCTAssertEqual(specification.width, .bandwidthOctaves(1.5))
            default:
                XCTAssertEqual(specification.width, .slopeDBPerOctave(10.8))
            }
        }
        let unknownKind = Data(
            encodedNodeJSON(type: "peaking", widthKind: "magic", widthValue: "1", corner: false).utf8
        )
        XCTAssertThrowsError(try M1ConfigurationCodec.decode(unknownKind))
    }

    func testV8NodeEnvelopeStillDecodes() throws {
        let v8Envelope = """
        {"schemaVersion":8,"nodes":[{"id":"\(testID.uuidString)","type":"preamp","isEnabled":true,"gainDB":-2}]}
        """
        let decoded = try M1NodeEnvelopeCodec.decode(Data(v8Envelope.utf8))
        XCTAssertEqual(decoded.nodes.count, 1)
        XCTAssertEqual(decoded.nodes[0].kind, .preamp)
        XCTAssertEqual(decoded.nodes[0].gainDB, -2)
    }

    func testV9ConfigurationReloadsThroughDecode() throws {
        let specification = M1FilterSpecification(
            type: .notch,
            frequencyHz: 800,
            gainDB: 0,
            width: .q(30),
            cornerFrequency: false
        )
        let snapshot = M1ConfigurationSnapshot(
            effectsEnabled: true,
            nodes: [.filter(specification: specification)]
        )
        let encoded = try M1ConfigurationCodec.encode(snapshot)
        let decoded = try M1ConfigurationCodec.decode(encoded.data)
        XCTAssertEqual(decoded.snapshot, encoded.snapshot)
    }

    private var testID = UUID()
    private var otherID = UUID()
}
