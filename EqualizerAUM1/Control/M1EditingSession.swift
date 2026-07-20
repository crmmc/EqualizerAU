import Foundation

enum M1SelectionMode: Sendable {
    case replacing
    case toggling
    case extending
}

enum M1NodeDragOperation: Equatable, Sendable {
    case move
    case copy
}

enum M1EditingSessionError: Error, Equatable, Sendable {
    case nodeNotFound
    case generationExhausted
    case invalidClipboard
    case unsupportedClipboardSchema(Int)
    case clipboardTooLarge(actual: Int, maximum: Int)
}

protocol M1PasteboardAccess: Sendable {
    func readNodes() async -> Data?
    func writeNodes(_ data: Data) async -> Bool
}

struct M1EncodedNodeEnvelope: Equatable, Sendable {
    let nodes: [M1PreampNode]
    let data: Data
}

enum M1NodeEnvelopeCodec {
    static let schemaVersion = 1
    static let maximumDataSize = M1ConfigurationCodec.maximumDataSize

    static func encode(_ nodes: [M1PreampNode]) throws -> M1EncodedNodeEnvelope {
        do {
            try M1ProcessingBuilder.validate(nodes: nodes)
        } catch let error as M1ProcessingBuildError {
            throw M1ConfigurationCodecError.invalidConfiguration(error)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(M1NodeEnvelopeWire(nodes: nodes))
        data.append(0x0A)
        guard data.count <= maximumDataSize else {
            throw M1EditingSessionError.clipboardTooLarge(
                actual: data.count,
                maximum: maximumDataSize
            )
        }
        return M1EncodedNodeEnvelope(nodes: nodes, data: data)
    }

    static func decode(_ data: Data) throws -> M1EncodedNodeEnvelope {
        guard data.count <= maximumDataSize else {
            throw M1EditingSessionError.clipboardTooLarge(
                actual: data.count,
                maximum: maximumDataSize
            )
        }
        let wire: M1NodeEnvelopeWire
        do {
            wire = try JSONDecoder().decode(M1NodeEnvelopeWire.self, from: data)
        } catch {
            throw M1EditingSessionError.invalidClipboard
        }
        guard wire.schemaVersion == schemaVersion else {
            throw M1EditingSessionError.unsupportedClipboardSchema(wire.schemaVersion)
        }
        do {
            return try encode(wire.nodes.map { try $0.node() })
        } catch let error as M1EditingSessionError {
            throw error
        } catch {
            throw M1EditingSessionError.invalidClipboard
        }
    }
}

private struct M1NodeEnvelopeWire: Codable {
    let schemaVersion: Int
    let nodes: [M1PreampNodeWire]

    init(nodes: [M1PreampNode]) {
        schemaVersion = M1NodeEnvelopeCodec.schemaVersion
        self.nodes = nodes.map(M1PreampNodeWire.init)
    }
}

struct M1EditingHistoryMetrics: Equatable, Sendable {
    let undoCount: Int
    let redoCount: Int
    let dataSize: Int
}

struct M1EditingSession: Sendable {
    static let maximumHistoryCount = 30
    static let maximumHistoryDataSize = 64 * 1024 * 1024

    private struct HistoryRecord: Sendable {
        let nodes: [M1PreampNode]
        let dataSize: Int
        let sequence: UInt64
    }

    private(set) var nodes: [M1PreampNode]
    private(set) var selectedNodeIDs: Set<UUID> = []
    private(set) var focusedNodeID: UUID?
    private(set) var selectionAnchorNodeID: UUID?
    private var undoStack: [HistoryRecord] = []
    private var redoStack: [HistoryRecord] = []
    private var nextSequence: UInt64 = 0
    private var activeGestureID: UUID?
    private var gestureRecordedHistory = false
    private let historyCountLimit: Int
    private let historyDataSizeLimit: Int

    init(
        nodes: [M1PreampNode],
        historyCountLimit: Int = Self.maximumHistoryCount,
        historyDataSizeLimit: Int = Self.maximumHistoryDataSize
    ) {
        self.nodes = nodes
        self.historyCountLimit = historyCountLimit
        self.historyDataSizeLimit = historyDataSizeLimit
        focusedNodeID = nodes.first?.id
        selectionAnchorNodeID = nodes.first?.id
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var orderedSelection: [UUID] {
        nodes.lazy.map(\.id).filter(selectedNodeIDs.contains)
    }
    var historyMetrics: M1EditingHistoryMetrics {
        M1EditingHistoryMetrics(
            undoCount: undoStack.count,
            redoCount: redoStack.count,
            dataSize: (undoStack + redoStack).reduce(0) { $0 + $1.dataSize }
        )
    }

    mutating func select(_ id: UUID?, mode: M1SelectionMode) {
        guard let id else {
            selectedNodeIDs.removeAll()
            return
        }
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        focusedNodeID = id
        switch mode {
        case .replacing:
            selectedNodeIDs = [id]
            selectionAnchorNodeID = id
        case .toggling:
            if selectedNodeIDs.contains(id) {
                selectedNodeIDs.remove(id)
            } else {
                selectedNodeIDs.insert(id)
            }
            selectionAnchorNodeID = id
        case .extending:
            let anchorID = selectionAnchorNodeID ?? focusedNodeID ?? id
            guard let anchorIndex = nodes.firstIndex(where: { $0.id == anchorID }) else {
                selectedNodeIDs = [id]
                selectionAnchorNodeID = id
                return
            }
            selectedNodeIDs = Set(nodes[min(anchorIndex, index)...max(anchorIndex, index)].map(\.id))
        }
    }

    mutating func selectAll() {
        selectedNodeIDs = Set(nodes.map(\.id))
        if focusedNodeID == nil {
            focusedNodeID = nodes.first?.id
            selectionAnchorNodeID = focusedNodeID
        }
    }

    mutating func replaceSelection(_ ids: Set<UUID>) {
        let valid = Set(nodes.map(\.id))
        selectedNodeIDs = ids.intersection(valid)
        if let first = nodes.first(where: { selectedNodeIDs.contains($0.id) })?.id {
            focusedNodeID = first
            selectionAnchorNodeID = first
        }
    }

    mutating func moveFocus(by offset: Int, extending: Bool) {
        guard !nodes.isEmpty else { return }
        let current = focusedNodeID.flatMap { id in nodes.firstIndex { $0.id == id } } ?? 0
        let destination = min(max(current + offset, 0), nodes.count - 1)
        let id = nodes[destination].id
        if extending {
            select(id, mode: .extending)
        } else {
            focusedNodeID = id
            selectionAnchorNodeID = id
        }
    }

    mutating func beginGesture(_ id: UUID) {
        guard activeGestureID != id else { return }
        activeGestureID = id
        gestureRecordedHistory = false
    }

    mutating func endGesture(_ id: UUID) {
        guard activeGestureID == id else { return }
        activeGestureID = nil
        gestureRecordedHistory = false
    }

    mutating func addPreamp(
        before id: UUID?,
        nodeID: UUID,
        effectsEnabled: Bool
    ) throws {
        var candidate = nodes
        let node = M1PreampNode(id: nodeID, isEnabled: true, gainDB: 0, channels: .all)
        if let id, let index = candidate.firstIndex(where: { $0.id == id }) {
            candidate.insert(node, at: index)
        } else {
            candidate.append(node)
        }
        try replaceNodes(candidate, effectsEnabled: effectsEnabled)
    }

    mutating func deleteNode(id: UUID, effectsEnabled: Bool) throws {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else {
            throw M1EditingSessionError.nodeNotFound
        }
        var candidate = nodes
        candidate.remove(at: index)
        try replaceNodes(candidate, effectsEnabled: effectsEnabled)
        selectedNodeIDs.remove(id)
        normalizeFocus(preferredIndex: index)
    }

    mutating func deleteSelection(effectsEnabled: Bool) throws {
        guard !selectedNodeIDs.isEmpty else { return }
        let firstIndex = nodes.firstIndex { selectedNodeIDs.contains($0.id) } ?? 0
        let candidate = nodes.filter { !selectedNodeIDs.contains($0.id) }
        try replaceNodes(candidate, effectsEnabled: effectsEnabled)
        selectedNodeIDs.removeAll()
        normalizeFocus(preferredIndex: firstIndex)
    }

    mutating func setNodeEnabled(id: UUID, enabled: Bool, effectsEnabled: Bool) throws {
        try updateNode(id: id, effectsEnabled: effectsEnabled) { $0.isEnabled = enabled }
    }

    mutating func setGainDB(id: UUID, gainDB: Double, effectsEnabled: Bool) throws {
        try updateNode(
            id: id,
            effectsEnabled: effectsEnabled,
            coalescingGestureID: id
        ) { $0.gainDB = gainDB }
    }

    mutating func setChannels(
        id: UUID,
        channels: M1ChannelSelection,
        effectsEnabled: Bool
    ) throws {
        try updateNode(id: id, effectsEnabled: effectsEnabled) { $0.channels = channels }
    }

    mutating func moveSelection(
        to destination: Int,
        operation: M1NodeDragOperation,
        copiedIDs: [UUID],
        effectsEnabled: Bool
    ) throws {
        let selected = nodes.enumerated().filter { selectedNodeIDs.contains($0.element.id) }
        guard !selected.isEmpty else { return }
        let sourceNodes = selected.map(\.element)
        let inserted: [M1PreampNode]
        switch operation {
        case .move:
            inserted = sourceNodes
        case .copy:
            guard copiedIDs.count == sourceNodes.count else {
                throw M1EditingSessionError.invalidClipboard
            }
            inserted = zip(sourceNodes, copiedIDs).map { node, id in
                M1PreampNode(
                    id: id,
                    isEnabled: node.isEnabled,
                    gainDB: node.gainDB,
                    channels: node.channels
                )
            }
        }

        var candidate = nodes
        var insertionIndex = min(max(destination, 0), candidate.count)
        if operation == .move {
            let indexes = selected.map(\.offset)
            candidate.removeAll { selectedNodeIDs.contains($0.id) }
            insertionIndex -= indexes.filter { $0 < insertionIndex }.count
            insertionIndex = min(max(insertionIndex, 0), candidate.count)
        }
        candidate.insert(contentsOf: inserted, at: insertionIndex)
        guard candidate != nodes else { return }
        try replaceNodes(candidate, effectsEnabled: effectsEnabled)
        selectedNodeIDs = Set(inserted.map(\.id))
        focusedNodeID = inserted.first?.id
        selectionAnchorNodeID = focusedNodeID
    }

    mutating func moveNode(id: UUID, to destination: Int, effectsEnabled: Bool) throws {
        guard let sourceIndex = nodes.firstIndex(where: { $0.id == id }) else {
            throw M1EditingSessionError.nodeNotFound
        }
        let boundedDestination = min(max(destination, 0), nodes.count - 1)
        guard sourceIndex != boundedDestination else { return }
        var candidate = nodes
        let node = candidate.remove(at: sourceIndex)
        candidate.insert(node, at: boundedDestination)
        try replaceNodes(candidate, effectsEnabled: effectsEnabled)
    }

    mutating func paste(
        _ pastedNodes: [M1PreampNode],
        newIDs: [UUID],
        effectsEnabled: Bool
    ) throws {
        guard !pastedNodes.isEmpty else { return }
        guard pastedNodes.count == newIDs.count else {
            throw M1EditingSessionError.invalidClipboard
        }
        let inserted = zip(pastedNodes, newIDs).map { node, id in
            M1PreampNode(
                id: id,
                isEnabled: node.isEnabled,
                gainDB: node.gainDB,
                channels: node.channels
            )
        }
        let insertionIndex = nodes.firstIndex { selectedNodeIDs.contains($0.id) } ?? nodes.count
        var candidate = nodes
        candidate.insert(contentsOf: inserted, at: insertionIndex)
        try replaceNodes(candidate, effectsEnabled: effectsEnabled)
        selectedNodeIDs = Set(inserted.map(\.id))
        focusedNodeID = inserted.first?.id
        selectionAnchorNodeID = focusedNodeID
    }

    mutating func undo(effectsEnabled: Bool) throws {
        guard let record = undoStack.popLast() else { return }
        let current = try makeRecord(nodes)
        redoStack.append(current)
        nodes = record.nodes
        normalizeSelection()
        _ = try M1ConfigurationCodec.encode(
            M1ConfigurationSnapshot(effectsEnabled: effectsEnabled, nodes: nodes)
        )
        trimHistory()
    }

    mutating func redo(effectsEnabled: Bool) throws {
        guard let record = redoStack.popLast() else { return }
        let current = try makeRecord(nodes)
        undoStack.append(current)
        nodes = record.nodes
        normalizeSelection()
        _ = try M1ConfigurationCodec.encode(
            M1ConfigurationSnapshot(effectsEnabled: effectsEnabled, nodes: nodes)
        )
        trimHistory()
    }

    func encodedSelection() throws -> M1EncodedNodeEnvelope? {
        let selected = nodes.filter { selectedNodeIDs.contains($0.id) }
        return selected.isEmpty ? nil : try M1NodeEnvelopeCodec.encode(selected)
    }

    private mutating func updateNode(
        id: UUID,
        effectsEnabled: Bool,
        coalescingGestureID: UUID? = nil,
        mutation: (inout M1PreampNode) -> Void
    ) throws {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else {
            throw M1EditingSessionError.nodeNotFound
        }
        var candidate = nodes
        mutation(&candidate[index])
        try replaceNodes(
            candidate,
            effectsEnabled: effectsEnabled,
            coalescingGestureID: coalescingGestureID
        )
    }

    private mutating func replaceNodes(
        _ candidate: [M1PreampNode],
        effectsEnabled: Bool,
        coalescingGestureID: UUID? = nil
    ) throws {
        guard candidate != nodes else { return }
        _ = try M1ConfigurationCodec.encode(
            M1ConfigurationSnapshot(effectsEnabled: effectsEnabled, nodes: candidate)
        )
        let coalesces = activeGestureID != nil && activeGestureID == coalescingGestureID
        if !coalesces {
            activeGestureID = nil
            gestureRecordedHistory = false
        }
        if !coalesces || !gestureRecordedHistory {
            undoStack.append(try makeRecord(nodes))
            redoStack.removeAll()
            gestureRecordedHistory = coalesces
        }
        nodes = candidate
        trimHistory()
    }

    private mutating func makeRecord(_ nodes: [M1PreampNode]) throws -> HistoryRecord {
        guard nextSequence < UInt64.max else { throw M1EditingSessionError.generationExhausted }
        nextSequence += 1
        let encoded = try M1NodeEnvelopeCodec.encode(nodes)
        return HistoryRecord(nodes: nodes, dataSize: encoded.data.count, sequence: nextSequence)
    }

    private mutating func trimHistory() {
        while undoStack.count + redoStack.count > historyCountLimit
            || historyMetrics.dataSize > historyDataSizeLimit {
            let oldestUndo = undoStack.enumerated().min { $0.element.sequence < $1.element.sequence }
            let oldestRedo = redoStack.enumerated().min { $0.element.sequence < $1.element.sequence }
            if let undo = oldestUndo,
               oldestRedo == nil || undo.element.sequence < oldestRedo!.element.sequence {
                undoStack.remove(at: undo.offset)
            } else if let redo = oldestRedo {
                redoStack.remove(at: redo.offset)
            } else {
                break
            }
        }
    }

    private mutating func normalizeSelection() {
        let valid = Set(nodes.map(\.id))
        selectedNodeIDs.formIntersection(valid)
        if let focusedNodeID, !valid.contains(focusedNodeID) {
            self.focusedNodeID = nodes.first?.id
        }
        if let selectionAnchorNodeID, !valid.contains(selectionAnchorNodeID) {
            self.selectionAnchorNodeID = focusedNodeID ?? nodes.first?.id
        }
    }

    private mutating func normalizeFocus(preferredIndex: Int) {
        guard !nodes.isEmpty else {
            focusedNodeID = nil
            selectionAnchorNodeID = nil
            return
        }
        let index = min(max(preferredIndex, 0), nodes.count - 1)
        focusedNodeID = nodes[index].id
        selectionAnchorNodeID = focusedNodeID
    }
}
