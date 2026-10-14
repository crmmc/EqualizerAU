import Accelerate
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
    case graphicEQFIRGenerationFailed(nodeID: UUID)
    case invalidGraphicEQTaps(nodeID: UUID)
    case invalidConvolutionIRReference(nodeID: UUID)
    case convolutionStageCapacityExceeded
    case invalidFilterSpecification(nodeID: UUID)
    case invalidFilterFrequency(nodeID: UUID)
    case invalidFilterGain(nodeID: UUID)
    case filterGainNotApplicable(nodeID: UUID)
    case invalidFilterWidth(nodeID: UUID)
    case invalidDelayValue(nodeID: UUID)
    case delayExceedsBudget(nodeID: UUID)
    case invalidDelaySampleRate(nodeID: UUID)
    case delayStageCapacityExceeded
    case invalidLoudnessSpecification(nodeID: UUID)
    case invalidLoudnessReferenceVolume(nodeID: UUID)
    case invalidLoudnessStrength(nodeID: UUID)
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

struct M1GraphicEQResolutionDiagnostic: Equatable, Sendable {
    let nodeID: UUID
    let maximumErrorDB: Double
    let percentile99ErrorDB: Double
}

struct M1GraphicEQPreview: Equatable, Sendable {
    let frequenciesHz: [Double]
    let targetGainDB: [Double]
    let compiledGainDB: [Double]
    let maximumErrorDB: Double
    let percentile99ErrorDB: Double
}

struct M1ProcessingBuildDiagnostics: Equatable, Sendable {
    let unresolvedChannels: [M1UnresolvedChannelDiagnostic]
    let clippingRiskChannels: [M1ChannelIdentifier]
    let gainBoundaries: [M1GainBoundaryDiagnostic]
    let graphicEQResolution: [M1GraphicEQResolutionDiagnostic]
    let convolutionSources: [M1ConvolutionSourceDiagnostic]
    let convolutionBypasses: [M1ConvolutionBypassDiagnostic]
    let filterBypasses: [M1FilterBypassDiagnostic]
    let delayBypasses: [M1DelayBypassDiagnostic]

    init(
        unresolvedChannels: [M1UnresolvedChannelDiagnostic],
        clippingRiskChannels: [M1ChannelIdentifier],
        gainBoundaries: [M1GainBoundaryDiagnostic],
        graphicEQResolution: [M1GraphicEQResolutionDiagnostic] = [],
        convolutionSources: [M1ConvolutionSourceDiagnostic] = [],
        convolutionBypasses: [M1ConvolutionBypassDiagnostic] = [],
        filterBypasses: [M1FilterBypassDiagnostic] = [],
        delayBypasses: [M1DelayBypassDiagnostic] = []
    ) {
        self.unresolvedChannels = unresolvedChannels
        self.clippingRiskChannels = clippingRiskChannels
        self.gainBoundaries = gainBoundaries
        self.graphicEQResolution = graphicEQResolution
        self.convolutionSources = convolutionSources
        self.convolutionBypasses = convolutionBypasses
        self.filterBypasses = filterBypasses
        self.delayBypasses = delayBypasses
    }
}

struct M1ConvolutionSourceDiagnostic: Equatable, Sendable {
    let nodeID: UUID
    let source: M1ConvolutionIRReference
    let sourceSampleRate: Double
    let sourceChannelCount: Int
    let sourceFrameCount: Int
    let targetSampleRate: Double
    let targetFrameCount: Int
    let hasPerformanceWarning: Bool
}

enum M1ConvolutionBypassReason: Equatable, Sendable {
    case resource(M1ConvolutionIRError)
    case channelCountMismatch(expected: Int, actual: Int)
}

struct M1ConvolutionBypassDiagnostic: Equatable, Sendable {
    let nodeID: UUID
    let source: M1ConvolutionIRReference
    let reason: M1ConvolutionBypassReason
}

struct M1FilterBypassDiagnostic: Equatable, Sendable {
    let nodeID: UUID
    let frequencyHz: Double
    let sampleRate: Double
    let reason: M1FilterBypassReason
}

struct M1DelayBypassDiagnostic: Equatable, Sendable {
    let nodeID: UUID
    let value: Double
    let unit: M1DelayUnit
    let sampleRate: Double
    let reason: M1DelayBypassReason
}

enum M1DelayBypassReason: Equatable, Sendable {
    case exceedsBudget
    case invalidSampleRate
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
    case convolution(nodeID: UUID, taps: [Float])
    case delay(nodeID: UUID, integerDelay: UInt32, fraction: Float)
}

struct M1CompiledPreampTargets: Equatable, Sendable {
    let linearGainsByChannel: [Float]
    let stagesByChannel: [[M1CompiledProcessingStage]]
    let diagnostics: M1ProcessingBuildDiagnostics
    let processingLatencyFrames: Int
}

enum M1ProcessingBuilder {
    private static let maximumStagesPerChannel = 512
    private static let maximumPreparedStageCount = 4_096
    static let maximumConvolutionStages = Int(EAUM1_MAX_CONVOLUTION_STAGES)
    static let maximumDelayStages = Int(EAUM1_MAX_DELAY_STAGES)
    private static let convolutionLatencyFrames = 0
    /// 48 kHz reference length; higher sample rates scale via `graphicEQTapCount(forSampleRate:)`.
    static let graphicEQTapCount = 16_384
    private static let graphicEQDesignLength = 32_768
    private static let graphicEQReferenceSampleRate = 48_000.0
    static let graphicEQMaximumResponseErrorDB = 0.75
    static let graphicEQPercentile99ResponseErrorDB = 0.1

    /// ADR-0020: `N(Fs) = 16384 × 2^max(0, ceil(log2(Fs / 48000)))`.
    static func graphicEQTapCount(forSampleRate sampleRate: Double) -> Int {
        guard sampleRate.isFinite, sampleRate > 0 else {
            return graphicEQTapCount
        }
        let ratio = sampleRate / graphicEQReferenceSampleRate
        guard ratio > 1 else {
            return graphicEQTapCount
        }
        let exponent = Int(ceil(log2(ratio)))
        guard exponent > 0, exponent < 31 else {
            return graphicEQTapCount
        }
        return graphicEQTapCount << exponent
    }

    static func graphicEQDesignLength(forSampleRate sampleRate: Double) -> Int {
        graphicEQTapCount(forSampleRate: sampleRate) * 2
    }
    private static let minimumGainDB = -100.0
    private static let maximumGainDB = 100.0
    private static let maximumFiniteGainDB = 20 * log10(Double(Float.greatestFiniteMagnitude))
    private static let minimumNormalGainDB = 20 * log10(Double(Float.leastNormalMagnitude))
    private static let graphicEQMagnitudeFloorDB = -100.0

    static func build(
        nodes: [M1ProcessingNode],
        layout: M1OutputLayoutSnapshot,
        irLoader: any M1ConvolutionIRLoading = M1ConvolutionIRStore(),
        loudnessVolumeDB: Double? = nil
    ) throws -> M1CompiledPreampTargets {
        try validate(nodes: nodes)

        var channelIndexes = Dictionary(
            uniqueKeysWithValues: layout.channels.map { ($0.identifier, $0.linearIndex) }
        )
        for channel in layout.channels {
            channelIndexes[M1ChannelIdentifier(String(channel.linearIndex + 1))!] = channel.linearIndex
        }
        var gainsByChannel = Array(repeating: [Double](), count: layout.channels.count)
        var pendingPreampGainsByChannel = Array(
            repeating: [(nodeID: UUID, gainDB: Double)](),
            count: layout.channels.count
        )
        var stagesByChannel = Array(repeating: [M1CompiledProcessingStage](), count: layout.channels.count)
        var unresolvedDiagnostics: [M1UnresolvedChannelDiagnostic] = []
        var graphicEQResolutionDiagnostics: [M1GraphicEQResolutionDiagnostic] = []
        var convolutionSources: [M1ConvolutionSourceDiagnostic] = []
        var convolutionBypasses: [M1ConvolutionBypassDiagnostic] = []
        var filterBypasses: [M1FilterBypassDiagnostic] = []
        var delayBypasses: [M1DelayBypassDiagnostic] = []
        var convolutionStageCount = 0
        var delayStageCount = 0
        var latencyByChannel = Array(repeating: 0, count: layout.channels.count)
        var reportedUnresolvedOwners: Set<UUID> = []

        var currentScope: M1ChannelSelection = .all
        var currentScopeNodeID: UUID?

        func appendConvolutionStage(nodeID: UUID, taps: [Float], channelIndex: Int) throws {
            appendPendingGainStage(
                channelIndex: channelIndex,
                pending: &pendingPreampGainsByChannel,
                stages: &stagesByChannel
            )
            convolutionStageCount += 1
            guard convolutionStageCount <= maximumConvolutionStages else {
                throw M1ProcessingBuildError.convolutionStageCapacityExceeded
            }
            stagesByChannel[channelIndex].append(.convolution(nodeID: nodeID, taps: taps))
            latencyByChannel[channelIndex] += convolutionLatencyFrames
        }

        for node in nodes {
            try Task.checkCancellation()
            if node.kind == .channels {
                if node.isEnabled {
                    currentScope = node.channels
                    currentScopeNodeID = node.id
                }
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
                var seenResolvedIndexes: Set<Int> = []
                var unresolvedIdentifiers: [M1ChannelIdentifier] = []
                resolvedIndexes.reserveCapacity(values.count)
                unresolvedIdentifiers.reserveCapacity(values.count)
                for identifier in values {
                    if let index = channelIndexes[identifier] {
                        if seenResolvedIndexes.insert(index).inserted {
                            resolvedIndexes.append(index)
                        }
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
                guard !selectedIndexes.isEmpty else { continue }
                guard let taps = try compileGraphicEQTaps(
                    nodeID: node.id,
                    points: node.graphicEQPoints,
                    sampleRate: layout.sampleRate
                ) else {
                    continue
                }
                let response = try graphicEQResponseMetrics(
                    nodeID: node.id,
                    taps: taps,
                    points: node.graphicEQPoints,
                    sampleRate: layout.sampleRate,
                    sampleCount: 193
                )
                if response.maximumErrorDB > graphicEQMaximumResponseErrorDB
                    || response.percentile99ErrorDB > graphicEQPercentile99ResponseErrorDB {
                    graphicEQResolutionDiagnostics.append(
                        M1GraphicEQResolutionDiagnostic(
                            nodeID: node.id,
                            maximumErrorDB: response.maximumErrorDB,
                            percentile99ErrorDB: response.percentile99ErrorDB
                        )
                    )
                }
                for index in selectedIndexes {
                    try appendConvolutionStage(nodeID: node.id, taps: taps, channelIndex: index)
                }
            case .filter:
                guard !selectedIndexes.isEmpty else { continue }
                guard let specification = node.filterSpecification else { continue }
                switch M1BiquadFilterDesign.design(
                    specification: specification,
                    sampleRate: layout.sampleRate
                ) {
                case .coefficients(let coefficients):
                    for index in selectedIndexes {
                        appendPendingGainStage(
                            channelIndex: index,
                            pending: &pendingPreampGainsByChannel,
                            stages: &stagesByChannel
                        )
                        stagesByChannel[index].append(
                            .biquad(nodeID: node.id, bandIndex: 0, coefficients: coefficients)
                        )
                    }
                case .bypass(let reason):
                    filterBypasses.append(
                        M1FilterBypassDiagnostic(
                            nodeID: node.id,
                            frequencyHz: specification.frequencyHz,
                            sampleRate: layout.sampleRate,
                            reason: reason
                        )
                    )
                }
            case .delay:
                guard !selectedIndexes.isEmpty else { continue }
                guard let specification = node.delaySpecification else { continue }
                let totalSamples = specification.samples(atSampleRate: layout.sampleRate)
                if let totalSamples,
                   totalSamples > 0,
                   totalSamples <= Double(M1DelayContract.maximumSamples) {
                    var integerDelay = UInt32(totalSamples.rounded(.down))
                    var fraction = Float(totalSamples - Double(integerDelay))
                    if fraction >= 1 {
                        integerDelay += 1
                        fraction = 0
                    }
                    // A subnormal total (hand-edited config only; the UI floor
                    // is 0.01) can collapse to (0, 0), which the runtime ABI
                    // rejects — bypass the node instead of failing prepare.
                    guard integerDelay != 0 || fraction != 0 else { continue }
                    for index in selectedIndexes {
                        delayStageCount += 1
                        guard delayStageCount <= maximumDelayStages else {
                            throw M1ProcessingBuildError.delayStageCapacityExceeded
                        }
                        appendPendingGainStage(
                            channelIndex: index,
                            pending: &pendingPreampGainsByChannel,
                            stages: &stagesByChannel
                        )
                        stagesByChannel[index].append(
                            .delay(
                                nodeID: node.id,
                                integerDelay: integerDelay,
                                fraction: fraction
                            )
                        )
                    }
                } else {
                    delayBypasses.append(
                        M1DelayBypassDiagnostic(
                            nodeID: node.id,
                            value: specification.value,
                            unit: specification.unit,
                            sampleRate: layout.sampleRate,
                            reason: totalSamples == nil ? .invalidSampleRate : .exceedsBudget
                        )
                    )
                }
            case .loudness:
                guard !selectedIndexes.isEmpty else { continue }
                guard let specification = node.loudnessSpecification else { continue }
                let currentVolumeDB = loudnessVolumeDB ?? specification.referenceVolumeDB
                let volumeStepDB = M1LoudnessContract.referenceVolumeStepDB
                let rawDeltaDB = currentVolumeDB - specification.referenceVolumeDB
                let volumeDeltaDB = (rawDeltaDB / volumeStepDB).rounded() * volumeStepDB
                guard let targetGainDB = M1EqualLoudnessCurve.compensationTargetGainDB(
                    referencePhon: M1EqualLoudnessCurve.assumedReferencePhon,
                    currentPhon: M1EqualLoudnessCurve.assumedReferencePhon + volumeDeltaDB,
                    strength: specification.strength
                ) else { continue }
                guard let taps = try compileMinimumPhaseTaps(
                    nodeID: node.id,
                    sampleRate: layout.sampleRate,
                    designLength: graphicEQDesignLength(forSampleRate: layout.sampleRate),
                    targetGainDB: targetGainDB
                ) else { continue }
                for index in selectedIndexes {
                    try appendConvolutionStage(nodeID: node.id, taps: taps, channelIndex: index)
                }
            case .convolution:
                guard !selectedIndexes.isEmpty else { continue }
                let reference = node.convolutionIR!
                let loaded: M1LoadedConvolutionIR
                do {
                    loaded = try irLoader.load(
                        reference: reference,
                        targetSampleRate: layout.sampleRate
                    )
                } catch let error as M1ConvolutionIRError {
                    convolutionBypasses.append(
                        M1ConvolutionBypassDiagnostic(
                            nodeID: node.id,
                            source: reference,
                            reason: .resource(error)
                        )
                    )
                    continue
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    convolutionBypasses.append(
                        M1ConvolutionBypassDiagnostic(
                            nodeID: node.id,
                            source: reference,
                            reason: .resource(.resourceIO)
                        )
                    )
                    continue
                }
                guard loaded.channels.count == 1 || loaded.channels.count == selectedIndexes.count else {
                    convolutionBypasses.append(
                        M1ConvolutionBypassDiagnostic(
                            nodeID: node.id,
                            source: reference,
                            reason: .channelCountMismatch(
                                expected: selectedIndexes.count,
                                actual: loaded.channels.count
                            )
                        )
                    )
                    continue
                }
                let effectiveChannels = loaded.channels.map(effectiveConvolutionTaps)
                convolutionSources.append(
                    M1ConvolutionSourceDiagnostic(
                        nodeID: node.id,
                        source: loaded.source,
                        sourceSampleRate: loaded.sourceSampleRate,
                        sourceChannelCount: loaded.sourceChannelCount,
                        sourceFrameCount: loaded.sourceFrameCount,
                        targetSampleRate: loaded.targetSampleRate,
                        targetFrameCount: loaded.channels[0].count,
                        hasPerformanceWarning: Double(loaded.sourceFrameCount)
                            > loaded.sourceSampleRate
                                * M1ConvolutionIRStore.performanceWarningDurationSeconds
                    )
                )
                for (selectionOffset, index) in selectedIndexes.enumerated() {
                    let taps = effectiveChannels.count == 1
                        ? effectiveChannels[0]
                        : effectiveChannels[selectionOffset]
                    try appendConvolutionStage(nodeID: node.id, taps: taps, channelIndex: index)
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

            let gain = floatTarget(totalGainDB: totalGainDB)
            if let boundary = gain.boundary {
                gainBoundaryDiagnostics.append(
                    M1GainBoundaryDiagnostic(
                        channel: channel.identifier,
                        boundary: boundary
                    )
                )
            }
            targets.append(gain.target)
        }

        return M1CompiledPreampTargets(
            linearGainsByChannel: targets,
            stagesByChannel: stagesByChannel,
            diagnostics: M1ProcessingBuildDiagnostics(
                unresolvedChannels: unresolvedDiagnostics,
                clippingRiskChannels: clippingRiskChannels,
                gainBoundaries: gainBoundaryDiagnostics,
                graphicEQResolution: graphicEQResolutionDiagnostics,
                convolutionSources: convolutionSources,
                convolutionBypasses: convolutionBypasses,
                filterBypasses: filterBypasses,
                delayBypasses: delayBypasses
            ),
            processingLatencyFrames: latencyByChannel.max() ?? 0
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
                guard node.graphicEQPoints.count <= M1GraphicEQContract.maximumPointCount else {
                    throw M1ProcessingBuildError.invalidGraphicEQBandCount(nodeID: node.id)
                }
                var previousFrequencyHz: Double?
                for (index, point) in node.graphicEQPoints.enumerated() {
                    guard point.frequencyHz.isFinite,
                          point.frequencyHz > 0,
                          previousFrequencyHz.map({ point.frequencyHz > $0 }) ?? true
                    else {
                        throw M1ProcessingBuildError.invalidGraphicEQFrequency(
                            nodeID: node.id,
                            bandIndex: index
                        )
                    }
                    guard point.gainDB.isFinite else {
                        throw M1ProcessingBuildError.nonFiniteGraphicEQGain(
                            nodeID: node.id,
                            bandIndex: index
                        )
                    }
                    guard point.gainDB >= M1GraphicEQContract.minimumGainDB,
                          point.gainDB <= M1GraphicEQContract.maximumGainDB
                    else {
                        throw M1ProcessingBuildError.graphicEQGainOutOfRange(
                            nodeID: node.id,
                            bandIndex: index
                        )
                    }
                    previousFrequencyHz = point.frequencyHz
                }
            }
            if node.kind == .convolution {
                guard let reference = node.convolutionIR,
                      !reference.sourcePath.isEmpty,
                      !reference.sourcePath.contains("\0"),
                      (reference.sourcePath as NSString).isAbsolutePath,
                      reference.sourcePath == URL(fileURLWithPath: reference.sourcePath).standardizedFileURL.path,
                      !reference.originalFileName.isEmpty
                else {
                    throw M1ProcessingBuildError.invalidConvolutionIRReference(nodeID: node.id)
                }
            }
            if node.kind == .filter {
                guard let specification = node.filterSpecification else {
                    throw M1ProcessingBuildError.invalidFilterSpecification(nodeID: node.id)
                }
                try specification.validate(nodeID: node.id)
            }
            if node.kind == .delay {
                guard let specification = node.delaySpecification else {
                    throw M1ProcessingBuildError.invalidDelayValue(nodeID: node.id)
                }
                try specification.validate(nodeID: node.id)
            }
            if node.kind == .loudness {
                guard let specification = node.loudnessSpecification else {
                    throw M1ProcessingBuildError.invalidLoudnessSpecification(nodeID: node.id)
                }
                try specification.validate(nodeID: node.id)
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

    static func graphicEQGainDB(
        frequencyHz: Double,
        points: [M1GraphicEQPoint]
    ) -> Double {
        guard !points.isEmpty else { return 0 }
        guard frequencyHz > points[0].frequencyHz else { return points[0].gainDB }
        guard frequencyHz < points[points.count - 1].frequencyHz else {
            return points[points.count - 1].gainDB
        }

        var lowerIndex = 0
        var upperIndex = points.count - 1
        while upperIndex - lowerIndex > 1 {
            let midpoint = (lowerIndex + upperIndex) / 2
            if frequencyHz < points[midpoint].frequencyHz {
                upperIndex = midpoint
            } else {
                lowerIndex = midpoint
            }
        }

        let lower = points[lowerIndex]
        let upper = points[upperIndex]
        let lowerLog = log(lower.frequencyHz)
        let upperLog = log(upper.frequencyHz)
        let position = (log(frequencyHz) - lowerLog) / (upperLog - lowerLog)
        return lower.gainDB + position * (upper.gainDB - lower.gainDB)
    }

    static func graphicEQProcessingGainDB(
        frequencyHz: Double,
        points: [M1GraphicEQPoint]
    ) -> Double {
        guard frequencyHz >= M1GraphicEQContract.minimumFrequencyHz,
              frequencyHz <= M1GraphicEQContract.maximumFrequencyHz else {
            return 0
        }
        return graphicEQGainDB(
            frequencyHz: frequencyHz,
            points: graphicEQProcessingPoints(points)
        )
    }

    static func graphicEQProcessingPoints(
        _ points: [M1GraphicEQPoint]
    ) -> [M1GraphicEQPoint] {
        points.filter {
            $0.frequencyHz >= M1GraphicEQContract.minimumFrequencyHz
                && $0.frequencyHz <= M1GraphicEQContract.maximumFrequencyHz
        }
    }

    private static func compileGraphicEQTaps(
        nodeID: UUID,
        points: [M1GraphicEQPoint],
        sampleRate: Double
    ) throws -> [Float]? {
        try compileGraphicEQTaps(
            nodeID: nodeID,
            points: points,
            sampleRate: sampleRate,
            designLength: graphicEQDesignLength(forSampleRate: sampleRate)
        )
    }

    /// Production uses sample-rate mapping; tests may pin `designLength` for contrast.
    static func graphicEQCompiledTaps(
        points: [M1GraphicEQPoint],
        sampleRate: Double,
        tapCount: Int
    ) throws -> [Float]? {
        try compileGraphicEQTaps(
            nodeID: UUID(),
            points: points,
            sampleRate: sampleRate,
            designLength: tapCount * 2
        )
    }

    private static func compileGraphicEQTaps(
        nodeID: UUID,
        points: [M1GraphicEQPoint],
        sampleRate: Double,
        designLength: Int
    ) throws -> [Float]? {
        let processingPoints = graphicEQProcessingPoints(points)
        guard !processingPoints.isEmpty else {
            return nil
        }
        return try compileMinimumPhaseTaps(
            nodeID: nodeID,
            sampleRate: sampleRate,
            designLength: designLength
        ) { frequencyHz in
            guard frequencyHz >= M1GraphicEQContract.minimumFrequencyHz,
                  frequencyHz <= M1GraphicEQContract.maximumFrequencyHz else {
                return 0
            }
            return graphicEQGainDB(frequencyHz: frequencyHz, points: processingPoints)
        }
    }

    /// Shared minimum-phase FIR compiler: builds the magnitude grid from any
    /// dB-per-frequency target (GraphicEQ control points, loudness curves)
    /// under the ADR-0020 length contract; a fully flat target yields no taps.
    private static func compileMinimumPhaseTaps(
        nodeID: UUID,
        sampleRate: Double,
        designLength: Int,
        targetGainDB: (Double) -> Double
    ) throws -> [Float]? {
        guard designLength >= 2,
              designLength.isMultiple(of: 2),
              (designLength & (designLength - 1)) == 0 else {
            throw M1ProcessingBuildError.graphicEQFIRGenerationFailed(nodeID: nodeID)
        }

        let halfLength = designLength / 2
        let magnitudeFloor = pow(10, graphicEQMagnitudeFloorDB / 20)
        var magnitudes = Array(repeating: 0.0, count: halfLength + 1)
        var isFlat = true
        for bin in 0...halfLength {
            if bin.isMultiple(of: 256) { try Task.checkCancellation() }
            let frequencyHz = sampleRate * Double(bin) / Double(designLength)
            let gainTargetDB = targetGainDB(frequencyHz)
            if gainTargetDB != 0 { isFlat = false }
            let gainDB = max(gainTargetDB, graphicEQMagnitudeFloorDB)
            let magnitude = max(pow(10, gainDB / 20), magnitudeFloor)
            guard magnitude.isFinite, magnitude > 0 else {
                throw M1ProcessingBuildError.graphicEQFIRGenerationFailed(nodeID: nodeID)
            }
            magnitudes[bin] = magnitude
        }
        return isFlat
            ? nil
            : try minimumPhaseTaps(
                nodeID: nodeID,
                magnitudes: magnitudes,
                designLength: designLength
            )
    }

    private static func minimumPhaseTaps(
        nodeID: UUID,
        magnitudes: [Double],
        designLength: Int
    ) throws -> [Float] {
        let halfLength = designLength / 2
        let tapCount = designLength / 2
        guard magnitudes.count == halfLength + 1 else {
            throw M1ProcessingBuildError.graphicEQFIRGenerationFailed(nodeID: nodeID)
        }
        let log2n = vDSP_Length(log2(Double(designLength)))
        try Task.checkCancellation()
        guard let setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) else {
            throw M1ProcessingBuildError.graphicEQFIRGenerationFailed(nodeID: nodeID)
        }
        defer { vDSP_destroy_fftsetupD(setup) }

        var logSpectrumReal = Array(repeating: 0.0, count: designLength)
        var logSpectrumImag = Array(repeating: 0.0, count: designLength)
        for bin in 0...halfLength {
            let magnitude = magnitudes[bin]
            guard magnitude.isFinite, magnitude > 0 else {
                throw M1ProcessingBuildError.graphicEQFIRGenerationFailed(nodeID: nodeID)
            }
            let value = log(magnitude)
            logSpectrumReal[bin] = value
            if bin > 0, bin < halfLength {
                logSpectrumReal[designLength - bin] = value
            }
        }

        fft(setup: setup, log2n: log2n, real: &logSpectrumReal, imag: &logSpectrumImag, direction: FFTDirection(FFT_INVERSE))
        try Task.checkCancellation()
        scale(values: &logSpectrumReal, by: 1.0 / Double(designLength))
        scale(values: &logSpectrumImag, by: 1.0 / Double(designLength))

        var minimumPhaseCepstrumReal = Array(repeating: 0.0, count: designLength)
        var minimumPhaseCepstrumImag = Array(repeating: 0.0, count: designLength)
        minimumPhaseCepstrumReal[0] = logSpectrumReal[0]
        for index in 1..<halfLength {
            minimumPhaseCepstrumReal[index] = 2 * logSpectrumReal[index]
        }
        minimumPhaseCepstrumReal[halfLength] = logSpectrumReal[halfLength]

        fft(
            setup: setup,
            log2n: log2n,
            real: &minimumPhaseCepstrumReal,
            imag: &minimumPhaseCepstrumImag,
            direction: FFTDirection(FFT_FORWARD)
        )
        try Task.checkCancellation()

        var impulseReal = Array(repeating: 0.0, count: designLength)
        var impulseImag = Array(repeating: 0.0, count: designLength)
        for index in 0..<designLength {
            let magnitude = exp(minimumPhaseCepstrumReal[index])
            guard magnitude.isFinite else {
                throw M1ProcessingBuildError.graphicEQFIRGenerationFailed(nodeID: nodeID)
            }
            impulseReal[index] = magnitude * cos(minimumPhaseCepstrumImag[index])
            impulseImag[index] = magnitude * sin(minimumPhaseCepstrumImag[index])
        }

        fft(setup: setup, log2n: log2n, real: &impulseReal, imag: &impulseImag, direction: FFTDirection(FFT_INVERSE))
        try Task.checkCancellation()
        scale(values: &impulseReal, by: 1.0 / Double(designLength))
        scale(values: &impulseImag, by: 1.0 / Double(designLength))

        var truncated = Array(impulseReal.prefix(tapCount))
        applyOneSidedCosineTaper(to: &truncated, designLength: designLength)

        var taps: [Float] = []
        taps.reserveCapacity(tapCount)
        for tap in truncated {
            if taps.count.isMultiple(of: 256) { try Task.checkCancellation() }
            guard tap.isFinite else {
                throw M1ProcessingBuildError.invalidGraphicEQTaps(nodeID: nodeID)
            }
            let normalizedTap = abs(tap) < Double(Float.leastNormalMagnitude) ? 0 : tap
            let floatTap = Float(normalizedTap)
            guard floatTap.isFinite else {
                throw M1ProcessingBuildError.invalidGraphicEQTaps(nodeID: nodeID)
            }
            taps.append(floatTap == 0 || floatTap.isNormal ? floatTap : 0)
        }
        guard taps.count == tapCount else {
            throw M1ProcessingBuildError.invalidGraphicEQTaps(nodeID: nodeID)
        }
        return taps
    }

    private static func fft(
        setup: FFTSetupD,
        log2n: vDSP_Length,
        real: inout [Double],
        imag: inout [Double],
        direction: FFTDirection
    ) {
        real.withUnsafeMutableBufferPointer { realBuffer in
            imag.withUnsafeMutableBufferPointer { imagBuffer in
                var split = DSPDoubleSplitComplex(
                    realp: realBuffer.baseAddress!,
                    imagp: imagBuffer.baseAddress!
                )
                vDSP_fft_zipD(setup, &split, 1, log2n, direction)
            }
        }
    }

    private static func scale(values: inout [Double], by factor: Double) {
        guard factor != 1 else { return }
        for index in values.indices {
            values[index] *= factor
        }
    }

    private static func applyOneSidedCosineTaper(to taps: inout [Double], designLength: Int) {
        for index in taps.indices {
            let weight = 0.5 * (
                1 + cos(2 * Double.pi * Double(index) / Double(designLength))
            )
            taps[index] *= weight
        }
    }

    static func graphicEQPreview(
        points: [M1GraphicEQPoint],
        sampleRate: Double,
        sampleCount: Int = 257
    ) throws -> M1GraphicEQPreview {
        let maximumFrequencyHz = min(M1GraphicEQContract.maximumFrequencyHz, sampleRate / 2)
        try validate(nodes: [.graphicEQ(points: points)])
        guard let taps = try compileGraphicEQTaps(
            nodeID: UUID(),
            points: points,
            sampleRate: sampleRate
        ) else {
            let frequencies = logarithmicGraphicEQFrequencies(
                sampleRate: sampleRate,
                sampleCount: sampleCount,
                maximumFrequencyHz: maximumFrequencyHz
            )
            return M1GraphicEQPreview(
                frequenciesHz: frequencies,
                targetGainDB: Array(repeating: 0, count: frequencies.count),
                compiledGainDB: Array(repeating: 0, count: frequencies.count),
                maximumErrorDB: 0,
                percentile99ErrorDB: 0
            )
        }
        let metrics = try graphicEQResponseMetrics(
            nodeID: UUID(),
            taps: taps,
            points: points,
            sampleRate: sampleRate,
            sampleCount: sampleCount,
            maximumFrequencyHz: maximumFrequencyHz
        )
        return M1GraphicEQPreview(
            frequenciesHz: metrics.frequenciesHz,
            targetGainDB: metrics.targetGainDB,
            compiledGainDB: metrics.compiledGainDB,
            maximumErrorDB: metrics.maximumErrorDB,
            percentile99ErrorDB: metrics.percentile99ErrorDB
        )
    }

    private static func graphicEQResponseMetrics(
        nodeID: UUID,
        taps: [Float],
        points: [M1GraphicEQPoint],
        sampleRate: Double,
        sampleCount: Int,
        maximumFrequencyHz: Double? = nil
    ) throws -> M1GraphicEQPreview {
        let frequencies = logarithmicGraphicEQFrequencies(
            sampleRate: sampleRate,
            sampleCount: sampleCount,
            maximumFrequencyHz: maximumFrequencyHz
        )
        try Task.checkCancellation()
        let processingPoints = graphicEQProcessingPoints(points)
        let target = frequencies.map { frequencyHz in
            guard frequencyHz >= M1GraphicEQContract.minimumFrequencyHz,
                  frequencyHz <= M1GraphicEQContract.maximumFrequencyHz else {
                return 0.0
            }
            return graphicEQGainDB(
                frequencyHz: frequencyHz,
                points: processingPoints
            )
        }
        let spectrum = try graphicEQMagnitudeSpectrum(taps: taps, nodeID: nodeID)
        let compiled = frequencies.map {
            graphicEQResponseDB(
                magnitudeSpectrum: spectrum,
                frequencyHz: $0,
                sampleRate: sampleRate
            )
        }
        let evaluationMaximum = min(
            M1GraphicEQContract.maximumResponseEvaluationFrequencyHz,
            sampleRate * 0.45
        )
        let errors = frequencies.indices.compactMap { index -> Double? in
            guard frequencies[index] >= M1GraphicEQContract.minimumResponseEvaluationFrequencyHz,
                  frequencies[index] <= evaluationMaximum else {
                return nil
            }
            return abs(target[index] - compiled[index])
        }.sorted()
        let percentileIndex = errors.isEmpty
            ? 0
            : min(errors.count - 1, Int(Double(errors.count - 1) * 0.99))
        return M1GraphicEQPreview(
            frequenciesHz: frequencies,
            targetGainDB: target,
            compiledGainDB: compiled,
            maximumErrorDB: errors.last ?? 0,
            percentile99ErrorDB: errors.isEmpty ? 0 : errors[percentileIndex]
        )
    }

    private static func logarithmicGraphicEQFrequencies(
        sampleRate: Double,
        sampleCount: Int,
        maximumFrequencyHz: Double? = nil
    ) -> [Double] {
        let lower = M1GraphicEQContract.minimumFrequencyHz
        let upper = maximumFrequencyHz ?? min(20_000, sampleRate * 0.45)
        guard sampleCount > 1, upper > lower else { return [lower] }
        let lowerLog = log(lower)
        let upperLog = log(upper)
        return (0..<sampleCount).map { index in
            let fraction = Double(index) / Double(sampleCount - 1)
            return exp(lowerLog + (upperLog - lowerLog) * fraction)
        }
    }

    private static func graphicEQMagnitudeSpectrum(
        taps: [Float],
        nodeID: UUID
    ) throws -> [Double] {
        let designLength = max(graphicEQDesignLength, taps.count * 2)
        let log2n = vDSP_Length(log2(Double(designLength)))
        guard let setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) else {
            throw M1ProcessingBuildError.graphicEQFIRGenerationFailed(nodeID: nodeID)
        }
        defer { vDSP_destroy_fftsetupD(setup) }
        var real = Array(repeating: 0.0, count: designLength)
        var imaginary = Array(repeating: 0.0, count: designLength)
        for index in taps.indices {
            real[index] = Double(taps[index])
        }
        fft(
            setup: setup,
            log2n: log2n,
            real: &real,
            imag: &imaginary,
            direction: FFTDirection(FFT_FORWARD)
        )
        try Task.checkCancellation()
        return (0...(designLength / 2)).map { hypot(real[$0], imaginary[$0]) }
    }

    private static func graphicEQResponseDB(
        magnitudeSpectrum: [Double],
        frequencyHz: Double,
        sampleRate: Double
    ) -> Double {
        let designLength = max(graphicEQDesignLength, (magnitudeSpectrum.count - 1) * 2)
        let position = min(
            max(frequencyHz * Double(designLength) / sampleRate, 0),
            Double(magnitudeSpectrum.count - 1)
        )
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, magnitudeSpectrum.count - 1)
        let fraction = position - Double(lower)
        let lowerLog = log(max(magnitudeSpectrum[lower], 1e-12))
        let upperLog = log(max(magnitudeSpectrum[upper], 1e-12))
        let magnitude = exp(lowerLog + (upperLog - lowerLog) * fraction)
        return 20 * log10(max(magnitude, 1e-12))
    }

    private static func effectiveConvolutionTaps(_ taps: [Float]) -> [Float] {
        guard let lastNonzeroIndex = taps.lastIndex(where: { $0 != 0 }) else {
            return [0]
        }
        guard lastNonzeroIndex != taps.index(before: taps.endIndex) else {
            return taps
        }
        return Array(taps[...lastNonzeroIndex])
    }

    /// Converts a total dB value into a Float linear gain. Branch order is
    /// load-bearing: the Float32 boundary tests pin exact adjacency via
    /// nextUp/nextDown, so the ceiling and floor checks must stay in this order.
    private static func floatTarget(
        totalGainDB: Double
    ) -> (target: Float, boundary: M1GainBoundary?) {
        if totalGainDB > maximumFiniteGainDB {
            return (Float.greatestFiniteMagnitude, .maximumFinite)
        }
        if totalGainDB < minimumNormalGainDB {
            return (0, .zeroBelowMinimumNormal)
        }
        let converted = Float(pow(10, totalGainDB / 20))
        if !converted.isFinite {
            return (Float.greatestFiniteMagnitude, .maximumFinite)
        }
        if converted != 0, !converted.isNormal {
            return (0, .zeroBelowMinimumNormal)
        }
        return (converted, nil)
    }

    private static func appendPendingGainStage(
        channelIndex: Int,
        pending: inout [[(nodeID: UUID, gainDB: Double)]],
        stages: inout [[M1CompiledProcessingStage]]
    ) {
        guard let first = pending[channelIndex].first else { return }
        let totalGainDB = pending[channelIndex].map { $0.gainDB }.sorted().reduce(0, +)
        pending[channelIndex].removeAll(keepingCapacity: true)
        let linearGain = floatTarget(totalGainDB: totalGainDB).target
        if linearGain != 1 {
            stages[channelIndex].append(
                .gain(nodeID: first.nodeID, linearGain: Double(linearGain))
            )
        }
    }
}
