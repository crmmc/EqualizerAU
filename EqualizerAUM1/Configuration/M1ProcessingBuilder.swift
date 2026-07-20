import Foundation

enum M1ProcessingBuildError: Error, Equatable, Sendable {
    case duplicateNodeID(UUID)
    case nonFiniteGain(nodeID: UUID)
    case gainOutOfRange(nodeID: UUID)
    case emptyChannelSelection(nodeID: UUID)
    case duplicateChannelIdentifier(nodeID: UUID, identifier: M1ChannelIdentifier)
}

struct M1UnresolvedChannelDiagnostic: Equatable, Sendable {
    let nodeID: UUID
    let identifiers: [M1ChannelIdentifier]
}

enum M1GainBoundary: Equatable, Sendable {
    case maximumFinite
    case zeroBelowMinimumNormal
}

struct M1GainBoundaryDiagnostic: Equatable, Sendable {
    let channel: M1ChannelIdentifier
    let boundary: M1GainBoundary
}

struct M1ProcessingBuildDiagnostics: Equatable, Sendable {
    let unresolvedChannels: [M1UnresolvedChannelDiagnostic]
    let clippingRiskChannels: [M1ChannelIdentifier]
    let gainBoundaries: [M1GainBoundaryDiagnostic]
}

struct M1CompiledPreampTargets: Equatable, Sendable {
    let linearGainsByChannel: [Float]
    let diagnostics: M1ProcessingBuildDiagnostics
}

enum M1ProcessingBuilder {
    private static let minimumGainDB = -100.0
    private static let maximumGainDB = 100.0
    private static let maximumFiniteGainDB = 20 * log10(Double(Float.greatestFiniteMagnitude))
    private static let minimumNormalGainDB = 20 * log10(Double(Float.leastNormalMagnitude))

    static func build(
        nodes: [M1ProcessingNode],
        layout: M1OutputLayoutSnapshot
    ) throws -> M1CompiledPreampTargets {
        try validate(nodes: nodes)

        let channelIndexes = Dictionary(
            uniqueKeysWithValues: layout.channels.map { ($0.identifier, $0.linearIndex) }
        )
        var gainsByChannel = Array(repeating: [Double](), count: layout.channels.count)
        var unresolvedDiagnostics: [M1UnresolvedChannelDiagnostic] = []
        var reportedUnresolvedOwners: Set<UUID> = []

        var currentScope: M1ChannelSelection = .all
        var currentScopeNodeID: UUID?
        for node in nodes {
            if node.kind == .channels {
                currentScope = node.channels
                currentScopeNodeID = node.id
                continue
            }
            guard node.isEnabled else { continue }
            let effectiveScope = node.channels == .all ? currentScope : node.channels
            let diagnosticNodeID = node.channels == .all ? currentScopeNodeID : node.id
            let selectedIndexes: [Int]
            switch effectiveScope {
            case .all:
                selectedIndexes = Array(layout.channels.indices)
            case let .identifiers(values):
                var resolvedIndexes: [Int] = []
                var unresolvedIdentifiers: [M1ChannelIdentifier] = []
                resolvedIndexes.reserveCapacity(values.count)
                unresolvedIdentifiers.reserveCapacity(values.count)
                for identifier in values {
                    if let index = channelIndexes[identifier] {
                        resolvedIndexes.append(index)
                    } else {
                        unresolvedIdentifiers.append(identifier)
                    }
                }
                let ownerID = diagnosticNodeID ?? node.id
                if !unresolvedIdentifiers.isEmpty,
                   reportedUnresolvedOwners.insert(ownerID).inserted {
                    unresolvedDiagnostics.append(
                        M1UnresolvedChannelDiagnostic(
                            nodeID: ownerID,
                            identifiers: unresolvedIdentifiers
                        )
                    )
                }
                selectedIndexes = resolvedIndexes
            }

            for index in selectedIndexes {
                gainsByChannel[index].append(node.gainDB)
            }
        }

        var targets: [Float] = []
        var clippingRiskChannels: [M1ChannelIdentifier] = []
        var gainBoundaryDiagnostics: [M1GainBoundaryDiagnostic] = []
        targets.reserveCapacity(layout.channels.count)

        for channel in layout.channels {
            let totalGainDB = gainsByChannel[channel.linearIndex].sorted().reduce(0, +)
            if totalGainDB > 0 {
                clippingRiskChannels.append(channel.identifier)
            }

            let target: Float
            if totalGainDB > maximumFiniteGainDB {
                target = Float.greatestFiniteMagnitude
                gainBoundaryDiagnostics.append(
                    M1GainBoundaryDiagnostic(
                        channel: channel.identifier,
                        boundary: .maximumFinite
                    )
                )
            } else if totalGainDB < minimumNormalGainDB {
                target = 0
                gainBoundaryDiagnostics.append(
                    M1GainBoundaryDiagnostic(
                        channel: channel.identifier,
                        boundary: .zeroBelowMinimumNormal
                    )
                )
            } else {
                let converted = Float(pow(10, totalGainDB / 20))
                if !converted.isFinite {
                    target = Float.greatestFiniteMagnitude
                    gainBoundaryDiagnostics.append(
                        M1GainBoundaryDiagnostic(
                            channel: channel.identifier,
                            boundary: .maximumFinite
                        )
                    )
                } else if converted != 0, !converted.isNormal {
                    target = 0
                    gainBoundaryDiagnostics.append(
                        M1GainBoundaryDiagnostic(
                            channel: channel.identifier,
                            boundary: .zeroBelowMinimumNormal
                        )
                    )
                } else {
                    target = converted
                }
            }
            targets.append(target)
        }

        return M1CompiledPreampTargets(
            linearGainsByChannel: targets,
            diagnostics: M1ProcessingBuildDiagnostics(
                unresolvedChannels: unresolvedDiagnostics,
                clippingRiskChannels: clippingRiskChannels,
                gainBoundaries: gainBoundaryDiagnostics
            )
        )
    }

    static func validate(nodes: [M1ProcessingNode]) throws {
        var nodeIDs = Set<UUID>()
        for node in nodes {
            guard nodeIDs.insert(node.id).inserted else {
                throw M1ProcessingBuildError.duplicateNodeID(node.id)
            }
            if node.kind == .preamp {
                guard node.gainDB.isFinite else {
                    throw M1ProcessingBuildError.nonFiniteGain(nodeID: node.id)
                }
                guard node.gainDB >= minimumGainDB, node.gainDB <= maximumGainDB else {
                    throw M1ProcessingBuildError.gainOutOfRange(nodeID: node.id)
                }
            }

            switch node.channels {
            case .all:
                continue
            case let .identifiers(values):
                guard !values.isEmpty else {
                    throw M1ProcessingBuildError.emptyChannelSelection(nodeID: node.id)
                }
                var seenIdentifiers = Set<M1ChannelIdentifier>()
                for identifier in values where !seenIdentifiers.insert(identifier).inserted {
                    throw M1ProcessingBuildError.duplicateChannelIdentifier(
                        nodeID: node.id,
                        identifier: identifier
                    )
                }
            }
        }
    }
}
