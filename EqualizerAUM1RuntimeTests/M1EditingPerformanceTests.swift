import Foundation
import XCTest

final class M1EditingPerformanceTests: XCTestCase {
    private let clock = ContinuousClock()

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["M5C_PERFORMANCE"] == "1",
            "Set M5C_PERFORMANCE=1 to run the M5-C performance baseline."
        )
    }

    func testM5CEditingBaseline() throws {
        let chainSize = 512
        let graphicEQID = UUID()
        let chain = makePreampNodes(count: chainSize - 1) + [M1ProcessingNode.graphicEQ(id: graphicEQID)]

        var editingSession = M1EditingSession(nodes: chain)
        var gains = M1GraphicEQContract.flatBands.map(\.gainDB)
        for index in gains.indices {
            gains[index] = Double(index) - 7
        }
        let graphicEQCloseCommit = try elapsed {
            try editingSession.setGraphicEQGainsDB(
                id: graphicEQID,
                gainsDB: gains,
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
            "bands": gains.count,
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

    private func report(_ name: String, _ duration: Duration, _ dimensions: [String: Int]) {
        let milliseconds = duration.components.seconds * 1_000
            + duration.components.attoseconds / 1_000_000_000_000_000
        let fields = dimensions.keys.sorted().map { "\($0)=\(dimensions[$0]!)" }.joined(separator: " ")
        print("M5C_METRIC name=\(name) milliseconds=\(milliseconds) \(fields)")
    }
}
