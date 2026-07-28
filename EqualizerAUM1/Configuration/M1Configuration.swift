import Foundation

struct M1ConfigurationSnapshot: Equatable, Sendable {
    static let schemaVersion = 8

    var effectsEnabled: Bool
    var nodes: [M1ProcessingNode]

    static func initial(nodeID: UUID = UUID()) -> Self {
        Self(
            effectsEnabled: true,
            nodes: [
                M1PreampNode(
                    id: nodeID,
                    isEnabled: true,
                    gainDB: 0,
                    channels: .all
                )
            ]
        )
    }

    static let transparentRecovery = Self(effectsEnabled: true, nodes: [])
}

struct M1EncodedConfiguration: Equatable, Sendable {
    let snapshot: M1ConfigurationSnapshot
    let data: Data

    fileprivate init(snapshot: M1ConfigurationSnapshot, data: Data) {
        self.snapshot = snapshot
        self.data = data
    }
}

enum M1ConfigurationCodecError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case unknownNodeType(String)
    case invalidChannelSelection
    case invalidConfiguration(M1ProcessingBuildError)
    case invalidJSON
    case exceedsMaximumSize(actual: Int, maximum: Int)
}

enum M1ConfigurationCodec {
    static let maximumDataSize = 4 * 1024 * 1024

    static func validateNodes(_ nodes: [M1ProcessingNode]) throws {
        do {
            try M1ProcessingBuilder.validate(nodes: nodes)
        } catch let error as M1ProcessingBuildError {
            throw M1ConfigurationCodecError.invalidConfiguration(error)
        }
    }

    static func encode(_ snapshot: M1ConfigurationSnapshot) throws -> M1EncodedConfiguration {
        let snapshot = M1ConfigurationSnapshot(
            effectsEnabled: snapshot.effectsEnabled,
            nodes: M1ConfigurationMigration.normalizedCurrentNodes(snapshot.nodes)
        )
        try validateNodes(snapshot.nodes)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data: Data
        do {
            data = try encoder.encode(M1ConfigurationWire(snapshot))
        } catch {
            throw M1ConfigurationCodecError.invalidJSON
        }
        data.append(0x0A)
        guard data.count <= maximumDataSize else {
            throw M1ConfigurationCodecError.exceedsMaximumSize(
                actual: data.count,
                maximum: maximumDataSize
            )
        }
        return M1EncodedConfiguration(snapshot: snapshot, data: data)
    }

    static func decode(_ data: Data) throws -> M1EncodedConfiguration {
        guard data.count <= maximumDataSize else {
            throw M1ConfigurationCodecError.exceedsMaximumSize(
                actual: data.count,
                maximum: maximumDataSize
            )
        }

        let version: M1ConfigurationVersionWire
        do {
            version = try JSONDecoder().decode(M1ConfigurationVersionWire.self, from: data)
        } catch let error as M1ConfigurationCodecError {
            throw error
        } catch {
            throw M1ConfigurationCodecError.invalidJSON
        }
        let snapshot: M1ConfigurationSnapshot
        switch version.schemaVersion {
        case 1:
            try M1JSONShapeValidator.validateConfiguration(data, schemaVersion: 1)
            let wire = try JSONDecoder().decode(M1ConfigurationV1Wire.self, from: data)
            snapshot = try wire.snapshot()
        case 2:
            try M1JSONShapeValidator.validateConfiguration(data, schemaVersion: 2)
            let wire = try JSONDecoder().decode(M1ConfigurationWire.self, from: data)
            snapshot = try wire.snapshot(expectedSchemaVersion: 2)
        case 3:
            try M1JSONShapeValidator.validateConfiguration(data, schemaVersion: 3)
            let wire = try JSONDecoder().decode(M1ConfigurationWire.self, from: data)
            snapshot = try wire.snapshot(expectedSchemaVersion: 3)
        case 4:
            try M1JSONShapeValidator.validateConfiguration(data, schemaVersion: 4)
            let wire = try JSONDecoder().decode(M1ConfigurationWire.self, from: data)
            snapshot = try wire.snapshot(expectedSchemaVersion: 4)
        case 5:
            try M1JSONShapeValidator.validateConfiguration(data, schemaVersion: 5)
            let wire = try JSONDecoder().decode(M1ConfigurationWire.self, from: data)
            snapshot = try wire.snapshot(expectedSchemaVersion: 5)
        case 6:
            try M1JSONShapeValidator.validateConfiguration(data, schemaVersion: 6)
            let wire = try JSONDecoder().decode(M1ConfigurationWire.self, from: data)
            snapshot = try wire.snapshot(expectedSchemaVersion: 6)
        case 7:
            try M1JSONShapeValidator.validateConfiguration(data, schemaVersion: 7)
            let wire = try JSONDecoder().decode(M1ConfigurationWire.self, from: data)
            snapshot = try wire.snapshot(expectedSchemaVersion: 7)
        case M1ConfigurationSnapshot.schemaVersion:
            try M1JSONShapeValidator.validateConfiguration(
                data,
                schemaVersion: M1ConfigurationSnapshot.schemaVersion
            )
            let wire = try JSONDecoder().decode(M1ConfigurationWire.self, from: data)
            snapshot = try wire.snapshot(expectedSchemaVersion: M1ConfigurationSnapshot.schemaVersion)
        default:
            throw M1ConfigurationCodecError.unsupportedSchema(version.schemaVersion)
        }
        return try encode(snapshot)
    }
}

enum M1JSONShapeValidator {
    static func validateConfiguration(_ data: Data, schemaVersion: Int) throws {
        try validateDocument(
            data,
            schemaVersion: schemaVersion,
            topLevelKeys: ["schemaVersion", "effectsEnabled", "nodes"]
        )
    }

    static func validateNodeEnvelope(_ data: Data, schemaVersion: Int) throws {
        try validateDocument(
            data,
            schemaVersion: schemaVersion,
            topLevelKeys: ["schemaVersion", "nodes"]
        )
    }

    private static func validateDocument(
        _ data: Data,
        schemaVersion: Int,
        topLevelKeys: Set<String>
    ) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw M1ConfigurationCodecError.invalidJSON
        }
        try M1JSONDuplicateKeyValidator.validate(data)
        guard let document = object as? [String: Any],
              Set(document.keys) == topLevelKeys,
              let nodes = document["nodes"] as? [[String: Any]]
        else {
            throw M1ConfigurationCodecError.invalidJSON
        }

        for node in nodes {
            guard let type = node["type"] as? String else {
                throw M1ConfigurationCodecError.invalidJSON
            }
            let allowedKeys: Set<String>
            if schemaVersion == 1 {
                allowedKeys = ["id", "type", "isEnabled", "gainDB", "channels"]
            } else {
                switch type {
                case M1ProcessingNodeKind.channels.rawValue:
                    allowedKeys = schemaVersion >= 5
                        ? ["id", "type", "isEnabled", "channels"]
                        : ["id", "type", "channels"]
                case M1ProcessingNodeKind.preamp.rawValue:
                    allowedKeys = ["id", "type", "isEnabled", "gainDB"]
                case M1ProcessingNodeKind.graphicEQ.rawValue where schemaVersion >= 6:
                    allowedKeys = ["id", "type", "isEnabled", "points"]
                    guard let points = node["points"] as? [[String: Any]],
                          points.allSatisfy({ Set($0.keys) == ["frequencyHz", "gainDB"] })
                    else {
                        throw M1ConfigurationCodecError.invalidJSON
                    }
                case M1ProcessingNodeKind.graphicEQ.rawValue where schemaVersion >= 3:
                    allowedKeys = ["id", "type", "isEnabled", "bands"]
                    guard let bands = node["bands"] as? [[String: Any]],
                          bands.allSatisfy({ Set($0.keys) == ["frequencyHz", "gainDB"] })
                    else {
                        throw M1ConfigurationCodecError.invalidJSON
                    }
                case M1ProcessingNodeKind.graphicEQ.rawValue:
                    throw M1ConfigurationCodecError.invalidJSON
                case M1ProcessingNodeKind.convolution.rawValue where schemaVersion >= 4:
                    allowedKeys = ["id", "type", "isEnabled", "ir"]
                    guard let ir = node["ir"] as? [String: Any] else {
                        throw M1ConfigurationCodecError.invalidJSON
                    }
                    let irKeys: Set<String> = schemaVersion >= 8
                        ? ["sourcePath"]
                        : [
                            "storageID", "originalFileName", "sha256", "sampleRate",
                            "channelCount", "frameCount",
                        ]
                    guard Set(ir.keys) == irKeys else {
                        throw M1ConfigurationCodecError.invalidJSON
                    }
                case M1ProcessingNodeKind.convolution.rawValue:
                    throw M1ConfigurationCodecError.invalidJSON
                default:
                    continue
                }
            }
            guard Set(node.keys) == allowedKeys else {
                throw M1ConfigurationCodecError.invalidJSON
            }
        }
    }
}

private enum M1JSONDuplicateKeyValidator {
    static func validate(_ data: Data) throws {
        var parser = Parser(data: data)
        try parser.parseDocument()
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        init(data: Data) { bytes = Array(data) }

        mutating func parseDocument() throws {
            skipWhitespace()
            try parseValue()
            skipWhitespace()
            guard index == bytes.count else { throw M1ConfigurationCodecError.invalidJSON }
        }

        private mutating func parseValue() throws {
            skipWhitespace()
            guard index < bytes.count else { throw M1ConfigurationCodecError.invalidJSON }
            switch bytes[index] {
            case 0x7B: try parseObject()
            case 0x5B: try parseArray()
            case 0x22: _ = try parseString()
            default:
                let start = index
                while index < bytes.count,
                      ![0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5D, 0x7D].contains(bytes[index]) {
                    index += 1
                }
                guard index > start else { throw M1ConfigurationCodecError.invalidJSON }
            }
        }

        private mutating func parseObject() throws {
            index += 1
            skipWhitespace()
            if consume(0x7D) { return }
            var keys = Set<String>()
            while true {
                let key = try parseString()
                guard keys.insert(key).inserted else { throw M1ConfigurationCodecError.invalidJSON }
                skipWhitespace()
                guard consume(0x3A) else { throw M1ConfigurationCodecError.invalidJSON }
                try parseValue()
                skipWhitespace()
                if consume(0x7D) { return }
                guard consume(0x2C) else { throw M1ConfigurationCodecError.invalidJSON }
                skipWhitespace()
            }
        }

        private mutating func parseArray() throws {
            index += 1
            skipWhitespace()
            if consume(0x5D) { return }
            while true {
                try parseValue()
                skipWhitespace()
                if consume(0x5D) { return }
                guard consume(0x2C) else { throw M1ConfigurationCodecError.invalidJSON }
            }
        }

        private mutating func parseString() throws -> String {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x22 else {
                throw M1ConfigurationCodecError.invalidJSON
            }
            let start = index
            index += 1
            while index < bytes.count {
                if bytes[index] == 0x5C {
                    index += 2
                } else if bytes[index] == 0x22 {
                    index += 1
                    do {
                        return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
                    } catch {
                        throw M1ConfigurationCodecError.invalidJSON
                    }
                } else {
                    index += 1
                }
            }
            throw M1ConfigurationCodecError.invalidJSON
        }

        private mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
                index += 1
            }
        }

        private mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }
    }
}

private struct M1ConfigurationVersionWire: Decodable {
    let schemaVersion: Int
}

private struct M1ConfigurationWire: Codable {
    let schemaVersion: Int
    let effectsEnabled: Bool
    let nodes: [M1ProcessingNodeWire]

    init(_ snapshot: M1ConfigurationSnapshot) {
        schemaVersion = M1ConfigurationSnapshot.schemaVersion
        effectsEnabled = snapshot.effectsEnabled
        nodes = snapshot.nodes.map { M1ProcessingNodeWire($0) }
    }

    func snapshot(expectedSchemaVersion: Int) throws -> M1ConfigurationSnapshot {
        guard schemaVersion == expectedSchemaVersion else {
            throw M1ConfigurationCodecError.unsupportedSchema(schemaVersion)
        }
        let decodedNodes: [M1ProcessingNode]
        do {
            decodedNodes = try nodes.map { try $0.node(schemaVersion: expectedSchemaVersion) }
        } catch let error as M1ProcessingBuildError {
            throw M1ConfigurationCodecError.invalidConfiguration(error)
        }
        let snapshot = M1ConfigurationSnapshot(
            effectsEnabled: effectsEnabled,
            nodes: decodedNodes
        )
        try M1ConfigurationCodec.validateNodes(snapshot.nodes)
        return snapshot
    }
}

private struct M1ConfigurationV1Wire: Decodable {
    let schemaVersion: Int
    let effectsEnabled: Bool
    let nodes: [M1PreampNodeWire]

    func snapshot() throws -> M1ConfigurationSnapshot {
        guard schemaVersion == 1 else {
            throw M1ConfigurationCodecError.unsupportedSchema(schemaVersion)
        }
        let legacyNodes = try nodes.map { try $0.node() }
        return M1ConfigurationSnapshot(
            effectsEnabled: effectsEnabled,
            nodes: M1ConfigurationMigration.migratedV1Nodes(legacyNodes)
        )
    }
}

struct M1ProcessingNodeWire: Codable {
    let id: UUID
    let type: String
    let isEnabled: Bool?
    let gainDB: Double?
    let channels: M1ChannelSelectionWire?
    let points: [M1GraphicEQPointWire]?
    let bands: [M1GraphicEQPointWire]?
    let ir: M1ConvolutionIRReferenceWire?

    init(_ node: M1ProcessingNode) {
        id = node.id
        type = node.kind.rawValue
        switch node.kind {
        case .channels:
            isEnabled = node.isEnabled
            gainDB = nil
            channels = M1ChannelSelectionWire(node.channels)
            points = nil
            bands = nil
            ir = nil
        case .preamp:
            isEnabled = node.isEnabled
            gainDB = node.gainDB
            channels = nil
            points = nil
            bands = nil
            ir = nil
        case .graphicEQ:
            isEnabled = node.isEnabled
            gainDB = nil
            channels = nil
            points = node.graphicEQPoints.map(M1GraphicEQPointWire.init)
            bands = nil
            ir = nil
        case .convolution:
            isEnabled = node.isEnabled
            gainDB = nil
            channels = nil
            points = nil
            bands = nil
            ir = node.convolutionIR.map(M1ConvolutionIRReferenceWire.init)
        }
    }

    func node(schemaVersion: Int) throws -> M1ProcessingNode {
        switch type {
        case M1ProcessingNodeKind.channels.rawValue:
            guard let channels, gainDB == nil, points == nil, bands == nil, ir == nil else {
                throw M1ConfigurationCodecError.invalidJSON
            }
            let enabled: Bool
            if schemaVersion >= 5 {
                guard let isEnabled else { throw M1ConfigurationCodecError.invalidJSON }
                enabled = isEnabled
            } else {
                guard isEnabled == nil else { throw M1ConfigurationCodecError.invalidJSON }
                enabled = true
            }
            return .channels(id: id, isEnabled: enabled, selection: try channels.selection())
        case M1ProcessingNodeKind.preamp.rawValue:
            guard let isEnabled, let gainDB, channels == nil, points == nil, bands == nil,
                  ir == nil else {
                throw M1ConfigurationCodecError.invalidJSON
            }
            return M1ProcessingNode(
                id: id,
                isEnabled: isEnabled,
                gainDB: gainDB,
                channels: .all
            )
        case M1ProcessingNodeKind.graphicEQ.rawValue:
            guard let isEnabled, gainDB == nil, channels == nil, ir == nil else {
                throw M1ConfigurationCodecError.invalidJSON
            }
            if schemaVersion >= 6 {
                guard let points, bands == nil else {
                    throw M1ConfigurationCodecError.invalidJSON
                }
                let decodedPoints = points.map(\.point)
                return .graphicEQ(
                    id: id,
                    isEnabled: isEnabled,
                    points: schemaVersion == 6
                        ? try M1GraphicEQModelValidator.migrateSchemaSixPoints(
                            decodedPoints,
                            nodeID: id
                        )
                        : decodedPoints
                )
            }
            guard let bands, points == nil else {
                throw M1ConfigurationCodecError.invalidJSON
            }
            return .graphicEQ(
                id: id,
                isEnabled: isEnabled,
                points: try M1GraphicEQModelValidator.migrateLegacyBands(
                    bands.map(\.point),
                    nodeID: id
                )
            )
        case M1ProcessingNodeKind.convolution.rawValue:
            guard let isEnabled, let ir, gainDB == nil, channels == nil, points == nil,
                  bands == nil else {
                throw M1ConfigurationCodecError.invalidJSON
            }
            return .convolution(
                id: id,
                isEnabled: isEnabled,
                ir: try ir.reference(schemaVersion: schemaVersion)
            )
        default:
            throw M1ConfigurationCodecError.unknownNodeType(type)
        }
    }
}

struct M1ConvolutionIRReferenceWire: Codable {
    let sourcePath: String?
    let storageID: UUID?
    let originalFileName: String?
    let sha256: String?
    let sampleRate: Double?
    let channelCount: Int?
    let frameCount: Int?

    init(_ reference: M1ConvolutionIRReference) {
        sourcePath = reference.sourcePath
        storageID = nil
        originalFileName = nil
        sha256 = nil
        sampleRate = nil
        channelCount = nil
        frameCount = nil
    }

    func reference(schemaVersion: Int) throws -> M1ConvolutionIRReference {
        if schemaVersion >= 8 {
            guard let sourcePath, storageID == nil, originalFileName == nil, sha256 == nil,
                  sampleRate == nil, channelCount == nil, frameCount == nil
            else {
                throw M1ConfigurationCodecError.invalidJSON
            }
            return M1ConvolutionIRReference(sourcePath: sourcePath)
        }
        guard sourcePath == nil, let storageID, let originalFileName, let sha256,
              let sampleRate, let channelCount, let frameCount
        else {
            throw M1ConfigurationCodecError.invalidJSON
        }
        guard !originalFileName.isEmpty,
              originalFileName == (originalFileName as NSString).lastPathComponent,
              sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({
                  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                      || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
              }),
              sampleRate.isFinite,
              sampleRate >= M1ConvolutionIRStore.minimumSampleRate,
              sampleRate <= M1ConvolutionIRStore.maximumSampleRate,
              (1...64).contains(channelCount),
              frameCount > 0,
              Double(frameCount) / sampleRate <= M1ConvolutionIRStore.maximumDurationSeconds
        else {
            throw M1ConfigurationCodecError.invalidJSON
        }
        return M1ConvolutionIRStore.legacyReference(storageID: storageID)
    }
}

struct M1GraphicEQPointWire: Codable {
    let frequencyHz: Double
    let gainDB: Double

    init(_ point: M1GraphicEQPoint) {
        frequencyHz = point.frequencyHz
        gainDB = point.gainDB
    }

    var point: M1GraphicEQPoint {
        M1GraphicEQPoint(frequencyHz: frequencyHz, gainDB: gainDB)
    }
}

private enum M1GraphicEQModelValidator {
    static func migrateSchemaSixPoints(
        _ points: [M1GraphicEQPoint],
        nodeID: UUID
    ) throws -> [M1GraphicEQPoint] {
        guard points.count <= M1GraphicEQContract.maximumPointCount else {
            throw M1ProcessingBuildError.invalidGraphicEQBandCount(nodeID: nodeID)
        }
        var previousFrequencyHz: Double?
        for (index, point) in points.enumerated() {
            guard point.frequencyHz.isFinite,
                  point.frequencyHz >= M1GraphicEQContract.minimumFrequencyHz,
                  point.frequencyHz <= M1GraphicEQContract.schemaSixMaximumFrequencyHz,
                  previousFrequencyHz.map({ point.frequencyHz > $0 }) ?? true else {
                throw M1ProcessingBuildError.invalidGraphicEQFrequency(
                    nodeID: nodeID,
                    bandIndex: index
                )
            }
            guard point.gainDB.isFinite else {
                throw M1ProcessingBuildError.nonFiniteGraphicEQGain(
                    nodeID: nodeID,
                    bandIndex: index
                )
            }
            guard point.gainDB >= M1GraphicEQContract.minimumGainDB,
                  point.gainDB <= M1GraphicEQContract.maximumGainDB else {
                throw M1ProcessingBuildError.graphicEQGainOutOfRange(
                    nodeID: nodeID,
                    bandIndex: index
                )
            }
            previousFrequencyHz = point.frequencyHz
        }
        return points
    }

    static func migrateLegacyBands(
        _ bands: [M1GraphicEQPoint],
        nodeID: UUID
    ) throws -> [M1GraphicEQPoint] {
        guard bands.count == M1GraphicEQContract.legacyCenterFrequenciesHz.count else {
            throw M1ProcessingBuildError.invalidGraphicEQBandCount(nodeID: nodeID)
        }
        for (index, band) in bands.enumerated() {
            guard band.frequencyHz == M1GraphicEQContract.legacyCenterFrequenciesHz[index] else {
                throw M1ProcessingBuildError.invalidGraphicEQFrequency(
                    nodeID: nodeID,
                    bandIndex: index
                )
            }
            guard band.gainDB.isFinite else {
                throw M1ProcessingBuildError.nonFiniteGraphicEQGain(
                    nodeID: nodeID,
                    bandIndex: index
                )
            }
            guard band.gainDB >= M1GraphicEQContract.legacyMinimumGainDB,
                  band.gainDB <= M1GraphicEQContract.legacyMaximumGainDB else {
                throw M1ProcessingBuildError.graphicEQGainOutOfRange(
                    nodeID: nodeID,
                    bandIndex: index
                )
            }
        }
        return bands
    }
}

struct M1PreampNodeWire: Codable {
    let id: UUID
    let type: String
    let isEnabled: Bool
    let gainDB: Double
    let channels: M1ChannelSelectionWire

    init(_ node: M1PreampNode) {
        id = node.id
        type = "preamp"
        isEnabled = node.isEnabled
        gainDB = node.gainDB
        channels = M1ChannelSelectionWire(node.channels)
    }

    func node() throws -> M1PreampNode {
        guard type == "preamp" else {
            throw M1ConfigurationCodecError.unknownNodeType(type)
        }
        return M1PreampNode(
            id: id,
            isEnabled: isEnabled,
            gainDB: gainDB,
            channels: try channels.selection()
        )
    }
}

enum M1ConfigurationMigration {
    static func migratedV1Nodes(_ nodes: [M1ProcessingNode]) -> [M1ProcessingNode] {
        var result: [M1ProcessingNode] = []
        result.reserveCapacity(nodes.count)
        var currentScope: M1ChannelSelection = .all
        var occupiedIDs = Set(nodes.map(\.id))

        for node in nodes {
            if node.channels != currentScope {
                currentScope = node.channels
                let id = uniqueMigratedChannelsID(
                    preampID: node.id,
                    selection: currentScope,
                    occupiedIDs: occupiedIDs
                )
                occupiedIDs.insert(id)
                result.append(
                    .channels(
                        id: id,
                        selection: currentScope
                    )
                )
            }
            result.append(
                M1ProcessingNode(
                    id: node.id,
                    isEnabled: node.isEnabled,
                    gainDB: node.gainDB,
                    channels: .all
                )
            )
        }
        return result
    }

    static func normalizedCurrentNodes(_ nodes: [M1ProcessingNode]) -> [M1ProcessingNode] {
        var result: [M1ProcessingNode] = []
        result.reserveCapacity(nodes.count)
        var currentScope: M1ChannelSelection = .all
        var occupiedIDs = Set(nodes.map(\.id))

        for node in nodes {
            switch node.kind {
            case .channels:
                if node.isEnabled { currentScope = node.channels }
                result.append(
                    .channels(
                        id: node.id,
                        isEnabled: node.isEnabled,
                        selection: node.channels
                    )
                )
            case .preamp:
                if node.channels != .all, node.channels != currentScope {
                    currentScope = node.channels
                    let id = uniqueMigratedChannelsID(
                        preampID: node.id,
                        selection: currentScope,
                        occupiedIDs: occupiedIDs
                    )
                    occupiedIDs.insert(id)
                    result.append(
                        .channels(
                            id: id,
                            selection: currentScope
                        )
                    )
                }
                result.append(
                    M1ProcessingNode(
                        id: node.id,
                        isEnabled: node.isEnabled,
                        gainDB: node.gainDB,
                        channels: .all
                    )
                )
            case .graphicEQ:
                if node.channels != .all, node.channels != currentScope {
                    currentScope = node.channels
                    let id = uniqueMigratedChannelsID(
                        preampID: node.id,
                        selection: currentScope,
                        occupiedIDs: occupiedIDs
                    )
                    occupiedIDs.insert(id)
                    result.append(.channels(id: id, selection: currentScope))
                }
                result.append(
                    .graphicEQ(
                        id: node.id,
                        isEnabled: node.isEnabled,
                        points: node.graphicEQPoints
                    )
                )
            case .convolution:
                if node.channels != .all, node.channels != currentScope {
                    currentScope = node.channels
                    let id = uniqueMigratedChannelsID(
                        preampID: node.id,
                        selection: currentScope,
                        occupiedIDs: occupiedIDs
                    )
                    occupiedIDs.insert(id)
                    result.append(.channels(id: id, selection: currentScope))
                }
                result.append(
                    .convolution(
                        id: node.id,
                        isEnabled: node.isEnabled,
                        ir: node.convolutionIR!
                    )
                )
            }
        }
        return result
    }

    private static func uniqueMigratedChannelsID(
        preampID: UUID,
        selection: M1ChannelSelection,
        occupiedIDs: Set<UUID>
    ) -> UUID {
        var salt: UInt64 = 0
        while true {
            let candidate = migratedChannelsID(
                preampID: preampID,
                selection: selection,
                salt: salt
            )
            if !occupiedIDs.contains(candidate) { return candidate }
            salt &+= 1
        }
    }

    private static func migratedChannelsID(
        preampID: UUID,
        selection: M1ChannelSelection,
        salt: UInt64
    ) -> UUID {
        var bytes = withUnsafeBytes(of: preampID.uuid) { Array($0) }
        let text: String
        switch selection {
        case .all:
            text = "all"
        case let .identifiers(values):
            text = values.map(\.rawValue).joined(separator: "\u{1F}")
        }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        for byte in withUnsafeBytes(of: salt.bigEndian, { Array($0) }) {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        for index in bytes.indices {
            bytes[index] ^= UInt8(truncatingIfNeeded: hash >> ((index % 8) * 8))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

enum M1ChannelSelectionWire: Codable {
    case all
    case identifiers([String])

    init(_ selection: M1ChannelSelection) {
        switch selection {
        case .all:
            self = .all
        case let .identifiers(values):
            self = .identifiers(values.map(\.rawValue))
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            guard value == "all" else {
                throw M1ConfigurationCodecError.invalidChannelSelection
            }
            self = .all
            return
        }
        self = .identifiers(try container.decode([String].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .all:
            try container.encode("all")
        case let .identifiers(values):
            try container.encode(values)
        }
    }

    func selection() throws -> M1ChannelSelection {
        switch self {
        case .all:
            return .all
        case let .identifiers(values):
            let identifiers = try values.map { value in
                guard let identifier = M1ChannelIdentifier(value) else {
                    throw M1ConfigurationCodecError.invalidChannelSelection
                }
                return identifier
            }
            return .identifiers(identifiers)
        }
    }
}
