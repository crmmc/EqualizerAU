import Foundation

struct M1ConfigurationSnapshot: Equatable, Sendable {
    static let schemaVersion = 1

    var effectsEnabled: Bool
    var nodes: [M1PreampNode]

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

    static func encode(_ snapshot: M1ConfigurationSnapshot) throws -> M1EncodedConfiguration {
        do {
            try M1ProcessingBuilder.validate(nodes: snapshot.nodes)
        } catch let error as M1ProcessingBuildError {
            throw M1ConfigurationCodecError.invalidConfiguration(error)
        }

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

        let wire: M1ConfigurationWire
        do {
            wire = try JSONDecoder().decode(M1ConfigurationWire.self, from: data)
        } catch let error as M1ConfigurationCodecError {
            throw error
        } catch {
            throw M1ConfigurationCodecError.invalidJSON
        }
        let snapshot = try wire.snapshot()
        return try encode(snapshot)
    }
}

private struct M1ConfigurationWire: Codable {
    let schemaVersion: Int
    let effectsEnabled: Bool
    let nodes: [M1PreampNodeWire]

    init(_ snapshot: M1ConfigurationSnapshot) {
        schemaVersion = M1ConfigurationSnapshot.schemaVersion
        effectsEnabled = snapshot.effectsEnabled
        nodes = snapshot.nodes.map { M1PreampNodeWire($0) }
    }

    func snapshot() throws -> M1ConfigurationSnapshot {
        guard schemaVersion == M1ConfigurationSnapshot.schemaVersion else {
            throw M1ConfigurationCodecError.unsupportedSchema(schemaVersion)
        }
        let snapshot = M1ConfigurationSnapshot(
            effectsEnabled: effectsEnabled,
            nodes: try nodes.map { try $0.node() }
        )
        do {
            try M1ProcessingBuilder.validate(nodes: snapshot.nodes)
        } catch let error as M1ProcessingBuildError {
            throw M1ConfigurationCodecError.invalidConfiguration(error)
        }
        return snapshot
    }
}

private struct M1PreampNodeWire: Codable {
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

private enum M1ChannelSelectionWire: Codable {
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
