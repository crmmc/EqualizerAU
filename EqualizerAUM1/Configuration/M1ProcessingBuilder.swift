import Foundation

enum M1ProcessingBuildError: Error, Equatable, Sendable {
    case duplicateNodeID(UUID)
    case nonFiniteGain(nodeID: UUID)
    case gainOutOfRange(nodeID: UUID)
    case emptyChannelSelection(nodeID: UUID)
    case duplicateChannelIdentifier(nodeID: UUID, identifier: M1ChannelIdentifier)
    case invalidGraphicEQBandCount(nodeID: UUID)
    case invalidGraphicEQFrequency(nodeID: UUID, bandIndex: Int)
    case nonFiniteGraphicEQGain(nodeID: UUID, bandIndex: Int)
    case graphicEQGainOutOfRange(nodeID: UUID, bandIndex: Int)
    case stageCapacityExceeded(channel: M1ChannelIdentifier)
    case totalStageCapacityExceeded
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
    let unavailableGraphicEQBands: [M1UnavailableGraphicEQBandDiagnostic]

    init(
        unresolvedChannels: [M1UnresolvedChannelDiagnostic],
        clippingRiskChannels: [M1ChannelIdentifier],
        gainBoundaries: [M1GainBoundaryDiagnostic],
        unavailableGraphicEQBands: [M1UnavailableGraphicEQBandDiagnostic] = []
    ) {
        self.unresolvedChannels = unresolvedChannels
        self.clippingRiskChannels = clippingRiskChannels
        self.gainBoundaries = gainBoundaries
        self.unavailableGraphicEQBands = unavailableGraphicEQBands
    }
}

struct M1UnavailableGraphicEQBandDiagnostic: Equatable, Sendable {
    let nodeID: UUID
    let frequencyHz: Double
}

struct M1BiquadCoefficients: Equatable, Sendable {
    let b0: Double
    let b1: Double
    let b2: Double
    let a1: Double
    let a2: Double
}

enum M1CompiledProcessingStage: Equatable, Sendable {
    case gain(nodeID: UUID, linearGain: Double)
    case biquad(nodeID: UUID, bandIndex: Int, coefficients: M1BiquadCoefficients)
}

struct M1CompiledPreampTargets: Equatable, Sendable {
    let linearGainsByChannel: [Float]
    let stagesByChannel: [[M1CompiledProcessingStage]]
    let diagnostics: M1ProcessingBuildDiagnostics
}

enum M1ProcessingBuilder {
    static let maximumStagesPerChannel = 512
    static let maximumPreparedStageCount = 4_096
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
        var pendingPreampGainsByChannel = Array(
            repeating: [(nodeID: UUID, gainDB: Double)](),
            count: layout.channels.count
        )
        var stagesByChannel = Array(repeating: [M1CompiledProcessingStage](), count: layout.channels.count)
        var unresolvedDiagnostics: [M1UnresolvedChannelDiagnostic] = []
        var unavailableGraphicEQBands: [M1UnavailableGraphicEQBandDiagnostic] = []
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

            switch node.kind {
            case .channels:
                break
            case .preamp:
                for index in selectedIndexes {
                    gainsByChannel[index].append(node.gainDB)
                    if node.gainDB != 0 {
                        pendingPreampGainsByChannel[index].append((node.id, node.gainDB))
                    }
                }
            case .graphicEQ:
                let availableBands: [M1CompiledProcessingStage] = node.graphicEQBands
                    .enumerated()
                    .compactMap { bandIndex, band in
                    guard band.frequencyHz < layout.sampleRate / 2 else {
                        unavailableGraphicEQBands.append(
                            M1UnavailableGraphicEQBandDiagnostic(
                                nodeID: node.id,
                                frequencyHz: band.frequencyHz
                            )
                        )
                        return nil
                    }
                    guard band.gainDB != 0 else { return nil }
                    return M1CompiledProcessingStage.biquad(
                        nodeID: node.id,
                        bandIndex: bandIndex,
                        coefficients: graphicEQCoefficients(
                            frequencyHz: band.frequencyHz,
                            gainDB: band.gainDB,
                            sampleRate: layout.sampleRate
                        )
                    )
                    }
                for index in selectedIndexes where !availableBands.isEmpty {
                    appendPendingGainStage(
                        channelIndex: index,
                        pending: &pendingPreampGainsByChannel,
                        stages: &stagesByChannel
                    )
                    stagesByChannel[index].append(contentsOf: availableBands)
                }
            }
        }

        for index in layout.channels.indices {
            appendPendingGainStage(
                channelIndex: index,
                pending: &pendingPreampGainsByChannel,
                stages: &stagesByChannel
            )
        }

        for channel in layout.channels
        where stagesByChannel[channel.linearIndex].count > maximumStagesPerChannel {
            throw M1ProcessingBuildError.stageCapacityExceeded(channel: channel.identifier)
        }
        guard stagesByChannel.reduce(0, { $0 + $1.count }) <= maximumPreparedStageCount else {
            throw M1ProcessingBuildError.totalStageCapacityExceeded
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
            stagesByChannel: stagesByChannel,
            diagnostics: M1ProcessingBuildDiagnostics(
                unresolvedChannels: unresolvedDiagnostics,
                clippingRiskChannels: clippingRiskChannels,
                gainBoundaries: gainBoundaryDiagnostics,
                unavailableGraphicEQBands: unavailableGraphicEQBands
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
            if node.kind == .graphicEQ {
                guard node.graphicEQBands.count == M1GraphicEQContract.centerFrequenciesHz.count else {
                    throw M1ProcessingBuildError.invalidGraphicEQBandCount(nodeID: node.id)
                }
                for (index, band) in node.graphicEQBands.enumerated() {
                    guard band.frequencyHz == M1GraphicEQContract.centerFrequenciesHz[index] else {
                        throw M1ProcessingBuildError.invalidGraphicEQFrequency(
                            nodeID: node.id,
                            bandIndex: index
                        )
                    }
                    guard band.gainDB.isFinite else {
                        throw M1ProcessingBuildError.nonFiniteGraphicEQGain(
                            nodeID: node.id,
                            bandIndex: index
                        )
                    }
                    guard band.gainDB >= M1GraphicEQContract.minimumGainDB,
                          band.gainDB <= M1GraphicEQContract.maximumGainDB
                    else {
                        throw M1ProcessingBuildError.graphicEQGainOutOfRange(
                            nodeID: node.id,
                            bandIndex: index
                        )
                    }
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

    private static func graphicEQCoefficients(
        frequencyHz: Double,
        gainDB: Double,
        sampleRate: Double
    ) -> M1BiquadCoefficients {
        let bandwidthRatio = pow(2, M1GraphicEQContract.octaveBandwidth)
        let q = sqrt(bandwidthRatio) / (bandwidthRatio - 1)
        let amplitude = pow(10, gainDB / 40)
        let omega = 2 * Double.pi * frequencyHz / sampleRate
        let alpha = sin(omega) / (2 * q)
        let cosine = cos(omega)
        let a0 = 1 + alpha / amplitude
        return M1BiquadCoefficients(
            b0: (1 + alpha * amplitude) / a0,
            b1: (-2 * cosine) / a0,
            b2: (1 - alpha * amplitude) / a0,
            a1: (-2 * cosine) / a0,
            a2: (1 - alpha / amplitude) / a0
        )
    }

    private static func appendPendingGainStage(
        channelIndex: Int,
        pending: inout [[(nodeID: UUID, gainDB: Double)]],
        stages: inout [[M1CompiledProcessingStage]]
    ) {
        guard let first = pending[channelIndex].first else { return }
        let totalGainDB = pending[channelIndex].map { $0.gainDB }.sorted().reduce(0, +)
        pending[channelIndex].removeAll(keepingCapacity: true)
        let linearGain: Float
        if totalGainDB > maximumFiniteGainDB {
            linearGain = Float.greatestFiniteMagnitude
        } else if totalGainDB < minimumNormalGainDB {
            linearGain = 0
        } else {
            let converted = Float(pow(10, totalGainDB / 20))
            if !converted.isFinite {
                linearGain = Float.greatestFiniteMagnitude
            } else if converted != 0, !converted.isNormal {
                linearGain = 0
            } else {
                linearGain = converted
            }
        }
        if linearGain != 1 {
            stages[channelIndex].append(
                .gain(nodeID: first.nodeID, linearGain: Double(linearGain))
            )
        }
    }
}
