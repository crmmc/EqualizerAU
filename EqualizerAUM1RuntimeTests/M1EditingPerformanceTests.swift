import Foundation
import XCTest

final class M1EditingPerformanceTests: XCTestCase {
    private let clock = ContinuousClock()

    override func setUpWithError() throws {
        try super.setUpWithError()
    }

    func testM5CEditingBaseline() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["M5C_PERFORMANCE"] == "1",
            "Set M5C_PERFORMANCE=1 to run the M5-C performance baseline."
        )
        let chainSize = 512
        let graphicEQID = UUID()
        let chain = makePreampNodes(count: chainSize - 1)
            + [M1ProcessingNode.graphicEQ(
                id: graphicEQID,
                points: M1GraphicEQContract.legacyFlatPoints
            )]

        var editingSession = M1EditingSession(nodes: chain)
        var points = M1GraphicEQContract.legacyFlatPoints
        for index in points.indices {
            points[index].gainDB = Double(index) - 7
        }
        let graphicEQCloseCommit = try elapsed {
            try editingSession.setGraphicEQPoints(
                id: graphicEQID,
                points: points,
                effectsEnabled: true
            )
        }
        XCTAssertEqual(editingSession.historyMetrics.undoCount, 1)

        editingSession.select(editingSession.nodes[0].id, mode: .replacing)
        let structuralMove = try elapsed {
            try editingSession.moveSelection(
                to: editingSession.nodes.count,
                operation: .move,
                copiedIDs: [],
                effectsEnabled: true
            )
        }

        let pasteFixture = try maximumLegalPaste(existingNodes: editingSession.nodes)
        var decodedNodes: [M1ProcessingNode] = []
        let clipboardDecode = try elapsed {
            decodedNodes = try M1NodeEnvelopeCodec.decode(pasteFixture.envelope.data).nodes
        }
        let paste = try elapsed {
            try editingSession.paste(
                decodedNodes,
                newIDs: pasteFixture.newIDs,
                effectsEnabled: true
            )
        }
        XCTAssertEqual(editingSession.selectedNodeIDs, Set(pasteFixture.newIDs))

        report("graphic_eq_close_commit", graphicEQCloseCommit, [
            "points": points.count,
            "chain_nodes": chainSize,
        ])
        report("structural_move", structuralMove, ["chain_nodes": chainSize])
        report("maximum_clipboard_decode", clipboardDecode, [
            "clipboard_bytes": pasteFixture.envelope.data.count,
            "pasted_nodes": pasteFixture.nodes.count,
        ])
        report("maximum_paste", paste, [
            "configuration_bytes": pasteFixture.configurationBytes,
            "existing_nodes": chainSize,
            "pasted_nodes": pasteFixture.nodes.count,
        ])
    }

    func testM6GraphicEQControlPerformance() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["M6_PERFORMANCE"] == "1",
            "Set M6_PERFORMANCE=1 to run the M6 performance baseline."
        )
        let points = makeGraphicEQPoints(count: M1GraphicEQContract.maximumPointCount)
        let layout = M1OutputLayoutSnapshot(
            sampleRate: 48_000,
            maximumFrameCount: 256,
            bufferChannelCounts: [2],
            semanticPositionsByChannelIndex: [.left, .right]
        )!
        let node = M1ProcessingNode.graphicEQ(points: points)

        var compiled: M1CompiledPreampTargets?
        let builder = try elapsed {
            compiled = try M1ProcessingBuilder.build(nodes: [node], layout: layout)
        }
        let result = try XCTUnwrap(compiled)
        var prepared: OpaquePointer?
        let preparedCreation = try elapsed {
            prepared = try M1RuntimePreparedStateFactory.create(
                stagesByChannel: result.stagesByChannel
            )
        }
        if let prepared { EAUM1PreparedStateDestroy(prepared) }
        let preview = try elapsed {
            _ = try M1ProcessingBuilder.graphicEQPreview(
                points: points,
                sampleRate: layout.sampleRate
            )
        }

        report("graphic_eq_fir_build", builder, [
            "channels": 2,
            "points": points.count,
            "taps": M1ProcessingBuilder.graphicEQTapCount,
        ], prefix: "M6_METRIC")
        report("graphic_eq_prepared_create", preparedCreation, [
            "channels": 2,
            "taps_per_channel": M1ProcessingBuilder.graphicEQTapCount,
        ], prefix: "M6_METRIC")
        report("graphic_eq_preview", preview, [
            "points": points.count,
            "samples": 257,
        ], prefix: "M6_METRIC")
    }

    private func makeGraphicEQPoints(count: Int) -> [M1GraphicEQPoint] {
        let lower = log(M1GraphicEQContract.minimumFrequencyHz)
        let upper = log(M1GraphicEQContract.maximumFrequencyHz)
        return (0..<count).map { index in
            let fraction = Double(index) / Double(count - 1)
            let frequencyHz: Double
            if index == 0 {
                frequencyHz = M1GraphicEQContract.minimumFrequencyHz
            } else if index == count - 1 {
                frequencyHz = M1GraphicEQContract.maximumFrequencyHz
            } else {
                frequencyHz = exp(lower + (upper - lower) * fraction)
            }
            return M1GraphicEQPoint(
                frequencyHz: frequencyHz,
                gainDB: 12 * sin(fraction * 4 * Double.pi)
            )
        }
    }

    private func maximumLegalPaste(existingNodes: [M1ProcessingNode]) throws -> (
        nodes: [M1ProcessingNode],
        envelope: M1EncodedNodeEnvelope,
        newIDs: [UUID],
        configurationBytes: Int
    ) {
        let maximumCandidateCount = 40_000
        let candidates = makePreampNodes(count: maximumCandidateCount)
        let candidateIDs = (0..<maximumCandidateCount).map { _ in UUID() }

        func encodedFixture(count: Int) throws -> (
            nodes: [M1ProcessingNode],
            envelope: M1EncodedNodeEnvelope,
            newIDs: [UUID],
            configurationBytes: Int
        ) {
            let nodes = Array(candidates.prefix(count))
            let newIDs = Array(candidateIDs.prefix(count))
            let envelope = try M1NodeEnvelopeCodec.encode(nodes)
            let copied = zip(nodes, newIDs).map { node, id in node.copied(id: id) }
            let configuration = try M1ConfigurationCodec.encode(
                M1ConfigurationSnapshot(effectsEnabled: true, nodes: existingNodes + copied)
            )
            return (nodes, envelope, newIDs, configuration.data.count)
        }

        XCTAssertThrowsError(try encodedFixture(count: maximumCandidateCount))
        var lowerBound = 0
        var upperBound = maximumCandidateCount
        while lowerBound + 1 < upperBound {
            let candidate = lowerBound + (upperBound - lowerBound) / 2
            if (try? encodedFixture(count: candidate)) != nil {
                lowerBound = candidate
            } else {
                upperBound = candidate
            }
        }
        let fixture = try encodedFixture(count: lowerBound)
        XCTAssertThrowsError(try encodedFixture(count: lowerBound + 1))
        return fixture
    }

    private func elapsed(_ operation: () throws -> Void) rethrows -> Duration {
        let start = clock.now
        try operation()
        return start.duration(to: clock.now)
    }

    private func makePreampNodes(count: Int) -> [M1ProcessingNode] {
        (0..<count).map { index in
            M1PreampNode(
                id: UUID(),
                isEnabled: index.isMultiple(of: 2),
                gainDB: Double(index % 201) / 10 - 10,
                channels: .all
            )
        }
    }

    private func report(
        _ name: String,
        _ duration: Duration,
        _ dimensions: [String: Int],
        prefix: String = "M5C_METRIC"
    ) {
        let milliseconds = duration.components.seconds * 1_000
            + duration.components.attoseconds / 1_000_000_000_000_000
        let fields = dimensions.keys.sorted().map { "\($0)=\(dimensions[$0]!)" }.joined(separator: " ")
        print("\(prefix) name=\(name) milliseconds=\(milliseconds) \(fields)")
    }
}
