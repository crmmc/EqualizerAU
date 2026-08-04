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

    init(
        unresolvedChannels: [M1UnresolvedChannelDiagnostic],
        clippingRiskChannels: [M1ChannelIdentifier],
        gainBoundaries: [M1GainBoundaryDiagnostic],
        graphicEQResolution: [M1GraphicEQResolutionDiagnostic] = [],
        convolutionSources: [M1ConvolutionSourceDiagnostic] = [],
        convolutionBypasses: [M1ConvolutionBypassDiagnostic] = []
    ) {
        self.unresolvedChannels = unresolvedChannels
        self.clippingRiskChannels = clippingRiskChannels
        self.gainBoundaries = gainBoundaries
        self.graphicEQResolution = graphicEQResolution
        self.convolutionSources = convolutionSources
        self.convolutionBypasses = convolutionBypasses
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
}

struct M1CompiledPreampTargets: Equatable, Sendable {
    let linearGainsByChannel: [Float]
    let stagesByChannel: [[M1CompiledProcessingStage]]
    let diagnostics: M1ProcessingBuildDiagnostics
    let processingLatencyFrames: Int
}

enum M1ProcessingBuilder {
    static let maximumStagesPerChannel = 512
    static let maximumPreparedStageCount = 4_096
    static let maximumConvolutionStages = Int(EAUM1_MAX_CONVOLUTION_STAGES)
    static let convolutionLatencyFrames = 0
    /// 48 kHz reference length; higher sample rates scale via `graphicEQTapCount(forSampleRate:)`.
    static let graphicEQTapCount = 16_384
    static let graphicEQDesignLength = 32_768
    static let graphicEQReferenceSampleRate = 48_000.0
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
        irLoader: any M1ConvolutionIRLoading = M1ConvolutionIRStore()
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
        var convolutionStageCount = 0
        var latencyByChannel = Array(repeating: 0, count: layout.channels.count)
        var reportedUnresolvedOwners: Set<UUID> = []

        var currentScope: M1ChannelSelection = .all
        var currentScopeNodeID: UUID?
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
                    appendPendingGainStage(
                        channelIndex: index,
                        pending: &pendingPreampGainsByChannel,
                        stages: &stagesByChannel
                    )
                    convolutionStageCount += 1
                    guard convolutionStageCount <= maximumConvolutionStages else {
                        throw M1ProcessingBuildError.convolutionStageCapacityExceeded
                    }
                    stagesByChannel[index].append(.convolution(nodeID: node.id, taps: taps))
                    latencyByChannel[index] += convolutionLatencyFrames
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
                    appendPendingGainStage(
                        channelIndex: index,
                        pending: &pendingPreampGainsByChannel,
                        stages: &stagesByChannel
                    )
                    let taps = effectiveChannels.count == 1
                        ? effectiveChannels[0]
                        : effectiveChannels[selectionOffset]
                    convolutionStageCount += 1
                    guard convolutionStageCount <= maximumConvolutionStages else {
                        throw M1ProcessingBuildError.convolutionStageCapacityExceeded
                    }
                    stagesByChannel[index].append(.convolution(nodeID: node.id, taps: taps))
                    latencyByChannel[index] += convolutionLatencyFrames
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
                graphicEQResolution: graphicEQResolutionDiagnostics,
                convolutionSources: convolutionSources,
                convolutionBypasses: convolutionBypasses
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
            let targetGainDB: Double
            if frequencyHz >= M1GraphicEQContract.minimumFrequencyHz,
               frequencyHz <= M1GraphicEQContract.maximumFrequencyHz {
                targetGainDB = graphicEQGainDB(
                    frequencyHz: frequencyHz,
                    points: processingPoints
                )
            } else {
                targetGainDB = 0
            }
            if targetGainDB != 0 { isFlat = false }
            let gainDB = max(targetGainDB, graphicEQMagnitudeFloorDB)
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
        try validate(nodes: [.graphicEQ(points: points)])
        guard let taps = try compileGraphicEQTaps(
            nodeID: UUID(),
            points: points,
            sampleRate: sampleRate
        ) else {
            let frequencies = logarithmicGraphicEQFrequencies(
                sampleRate: sampleRate,
                sampleCount: sampleCount,
                maximumFrequencyHz: min(M1GraphicEQContract.maximumFrequencyHz, sampleRate / 2)
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
            maximumFrequencyHz: min(M1GraphicEQContract.maximumFrequencyHz, sampleRate / 2)
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
