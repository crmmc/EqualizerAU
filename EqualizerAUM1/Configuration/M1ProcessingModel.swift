import Foundation

struct M1ChannelIdentifier: Hashable, Sendable {
    let rawValue: String

    init?(_ value: String) {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !normalized.isEmpty, normalized != "ALL" else {
            return nil
        }

        if normalized.allSatisfy({ $0.isASCII && $0.isNumber }) {
            guard let index = UInt(normalized), index > 0 else {
                return nil
            }
            rawValue = String(index)
        } else {
            rawValue = normalized
        }
    }
}

enum M1ChannelSelection: Equatable, Sendable {
    case all
    case identifiers([M1ChannelIdentifier])
}

enum M1ProcessingNodeKind: String, Sendable {
    case channels
    case preamp
    case graphicEQ
    case convolution
    case filter
}

struct M1ConvolutionIRReference: Equatable, Sendable {
    let sourcePath: String

    var originalFileName: String {
        URL(fileURLWithPath: sourcePath).lastPathComponent
    }
}

struct M1GraphicEQPoint: Equatable, Sendable {
    let frequencyHz: Double
    var gainDB: Double
}

enum M1GraphicEQContract {
    static let minimumFrequencyHz = 20.0
    static let maximumFrequencyHz = 20_000.0
    static let schemaSixMaximumFrequencyHz = 30_000.0
    static let minimumResponseEvaluationFrequencyHz = 40.0
    static let maximumResponseEvaluationFrequencyHz = 18_000.0
    static let maximumPointCount = 512
    static let legacyMinimumGainDB = -24.0
    static let legacyMaximumGainDB = 24.0
    static let minimumGainDB = -24.0
    static let maximumGainDB = 24.0
    static let gainStepDB = 0.1
    static let octaveBandwidth = 2.0 / 3.0
    static let legacyCenterFrequenciesHz: [Double] = [
        25, 40, 63, 100, 160, 250, 400, 630,
        1_000, 1_600, 2_500, 4_000, 6_300, 10_000, 16_000,
    ]

    static var flatPoints: [M1GraphicEQPoint] { [] }

    static var legacyFlatPoints: [M1GraphicEQPoint] {
        legacyCenterFrequenciesHz.map { M1GraphicEQPoint(frequencyHz: $0, gainDB: 0) }
    }
}

enum M1FilterType: String, CaseIterable, Sendable {
    case peaking
    case lowPass
    case highPass
    case bandPass
    case lowShelf
    case highShelf
    case notch
    case allPass

    var supportsGain: Bool {
        switch self {
        case .peaking, .lowShelf, .highShelf:
            return true
        case .lowPass, .highPass, .bandPass, .notch, .allPass:
            return false
        }
    }

    var isShelf: Bool {
        self == .lowShelf || self == .highShelf
    }
}

enum M1FilterWidth: Hashable, Sendable {
    case q(Double)
    case bandwidthOctaves(Double)
    case slopeDBPerOctave(Double)
}

enum M1FilterContract {
    /// Filter nodes use a wider frequency domain than Graphic EQ: subsonic
    /// protection filters (10–15 Hz high-pass) are a real use case and biquads
    /// carry no FIR design-grid constraint.
    static let minimumFrequencyHz = 1.0
    static let maximumFrequencyHz = 20_000.0
    static let minimumGainDB = -24.0
    static let maximumGainDB = 24.0
    static let gainStepDB = 0.1
    static let minimumQ = 0.05
    static let maximumQ = 100.0
    static let minimumBandwidthOctaves = 0.01
    static let maximumBandwidthOctaves = 12.0
    static let maximumSlopeDBPerOctave = 12.0
    /// EqualizerAPO `BiQuadFilterFactory` default for low/high/band-pass (M_SQRT1_2).
    static let defaultQ = 1.0 / 2.0.squareRoot()
    /// EqualizerAPO `BiQuadFilterFactory` default notch Q.
    static let defaultNotchQ = 30.0
    /// EqualizerAPO default shelf slope: 0.9 normalized × 12 dB/oct.
    static let defaultShelfSlopeDBPerOctave = 10.8
    static let defaultFrequencyHz = 1_000.0
}

struct M1FilterSpecification: Hashable, Sendable {
    var type: M1FilterType
    var frequencyHz: Double
    var gainDB: Double
    var width: M1FilterWidth
    var cornerFrequency: Bool

    static func defaultSpecification(type: M1FilterType = .peaking) -> Self {
        let width: M1FilterWidth
        switch type {
        case .lowShelf, .highShelf:
            width = .slopeDBPerOctave(M1FilterContract.defaultShelfSlopeDBPerOctave)
        case .notch:
            width = .q(M1FilterContract.defaultNotchQ)
        case .peaking, .lowPass, .highPass, .bandPass, .allPass:
            width = .q(M1FilterContract.defaultQ)
        }
        return Self(
            type: type,
            frequencyHz: M1FilterContract.defaultFrequencyHz,
            gainDB: 0,
            width: width,
            cornerFrequency: type.isShelf
        )
    }

    func validate(nodeID: UUID) throws {
        guard frequencyHz.isFinite,
              frequencyHz >= M1FilterContract.minimumFrequencyHz,
              frequencyHz <= M1FilterContract.maximumFrequencyHz
        else {
            throw M1ProcessingBuildError.invalidFilterFrequency(nodeID: nodeID)
        }
        guard gainDB.isFinite else {
            throw M1ProcessingBuildError.invalidFilterGain(nodeID: nodeID)
        }
        if type.supportsGain {
            guard gainDB >= M1FilterContract.minimumGainDB,
                  gainDB <= M1FilterContract.maximumGainDB
            else {
                throw M1ProcessingBuildError.invalidFilterGain(nodeID: nodeID)
            }
        } else {
            guard gainDB == 0 else {
                throw M1ProcessingBuildError.filterGainNotApplicable(nodeID: nodeID)
            }
        }
        switch width {
        case .q(let value):
            guard value.isFinite,
                  value >= M1FilterContract.minimumQ,
                  value <= M1FilterContract.maximumQ
            else {
                throw M1ProcessingBuildError.invalidFilterWidth(nodeID: nodeID)
            }
        case .bandwidthOctaves(let value):
            guard !type.isShelf,
                  value.isFinite,
                  value >= M1FilterContract.minimumBandwidthOctaves,
                  value <= M1FilterContract.maximumBandwidthOctaves
            else {
                throw M1ProcessingBuildError.invalidFilterWidth(nodeID: nodeID)
            }
        case .slopeDBPerOctave(let value):
            guard type.isShelf,
                  value.isFinite,
                  value > 0,
                  value <= M1FilterContract.maximumSlopeDBPerOctave
            else {
                throw M1ProcessingBuildError.invalidFilterWidth(nodeID: nodeID)
            }
        }
        guard type.isShelf || !cornerFrequency else {
            throw M1ProcessingBuildError.invalidFilterSpecification(nodeID: nodeID)
        }
    }
}

extension M1FilterSpecification {
    /// Numeric value of the current width, regardless of kind.
    var widthValue: Double? {
        switch width {
        case .q(let value):
            return value
        case .bandwidthOctaves(let value):
            return value
        case .slopeDBPerOctave(let value):
            return value
        }
    }

    func withType(_ type: M1FilterType) -> Self {
        var result = self
        guard type != self.type else { return result }
        result.type = type
        result.cornerFrequency = type.isShelf
        switch result.width {
        case .slopeDBPerOctave where !type.isShelf:
            result.width = .q(M1FilterContract.defaultQ)
        case .bandwidthOctaves where type.isShelf:
            result.width = .slopeDBPerOctave(M1FilterContract.defaultShelfSlopeDBPerOctave)
        case .q, .bandwidthOctaves, .slopeDBPerOctave:
            break
        }
        if !type.supportsGain { result.gainDB = 0 }
        return result
    }

    func withFrequencyHz(_ value: Double) -> Self {
        var result = self
        result.frequencyHz = value
        return result
    }

    func withGainDB(_ value: Double) -> Self {
        var result = self
        result.gainDB = value
        return result
    }

    func withWidth(_ width: M1FilterWidth) -> Self {
        var result = self
        result.width = width
        return result
    }

    func withWidthValue(_ value: Double) -> Self {
        var result = self
        switch result.width {
        case .q:
            result.width = .q(value)
        case .bandwidthOctaves:
            result.width = .bandwidthOctaves(value)
        case .slopeDBPerOctave:
            result.width = .slopeDBPerOctave(value)
        }
        return result
    }

    func withCornerFrequency(_ cornerFrequency: Bool) -> Self {
        var result = self
        result.cornerFrequency = cornerFrequency
        return result
    }
}

struct M1ProcessingNode: Identifiable, Equatable, Sendable {
    let id: UUID
    var kind: M1ProcessingNodeKind
    var isEnabled: Bool
    var gainDB: Double
    var channels: M1ChannelSelection
    var graphicEQPoints: [M1GraphicEQPoint]
    var convolutionIR: M1ConvolutionIRReference?
    var filterSpecification: M1FilterSpecification?

    init(
        id: UUID,
        isEnabled: Bool,
        gainDB: Double,
        channels: M1ChannelSelection
    ) {
        self.id = id
        kind = .preamp
        self.isEnabled = isEnabled
        self.gainDB = gainDB
        self.channels = channels
        graphicEQPoints = []
        convolutionIR = nil
        filterSpecification = nil
    }

    static func channels(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        selection: M1ChannelSelection
    ) -> Self {
        Self(
            id: id,
            kind: .channels,
            isEnabled: isEnabled,
            gainDB: 0,
            channels: selection,
            graphicEQPoints: [],
            convolutionIR: nil
        )
    }

    static func graphicEQ(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        points: [M1GraphicEQPoint] = M1GraphicEQContract.flatPoints
    ) -> Self {
        Self(
            id: id,
            kind: .graphicEQ,
            isEnabled: isEnabled,
            gainDB: 0,
            channels: .all,
            graphicEQPoints: points,
            convolutionIR: nil
        )
    }

    static func convolution(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        ir: M1ConvolutionIRReference
    ) -> Self {
        Self(
            id: id,
            kind: .convolution,
            isEnabled: isEnabled,
            gainDB: 0,
            channels: .all,
            graphicEQPoints: [],
            convolutionIR: ir
        )
    }

    static func filter(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        specification: M1FilterSpecification = .defaultSpecification()
    ) -> Self {
        Self(
            id: id,
            kind: .filter,
            isEnabled: isEnabled,
            gainDB: 0,
            channels: .all,
            graphicEQPoints: [],
            convolutionIR: nil,
            filterSpecification: specification
        )
    }

    private init(
        id: UUID,
        kind: M1ProcessingNodeKind,
        isEnabled: Bool,
        gainDB: Double,
        channels: M1ChannelSelection,
        graphicEQPoints: [M1GraphicEQPoint],
        convolutionIR: M1ConvolutionIRReference?,
        filterSpecification: M1FilterSpecification? = nil
    ) {
        self.id = id
        self.kind = kind
        self.isEnabled = isEnabled
        self.gainDB = gainDB
        self.channels = channels
        self.graphicEQPoints = graphicEQPoints
        self.convolutionIR = convolutionIR
        self.filterSpecification = filterSpecification
    }

    func copied(id: UUID) -> Self {
        switch kind {
        case .channels:
            return .channels(id: id, isEnabled: isEnabled, selection: channels)
        case .preamp:
            return Self(
                id: id,
                isEnabled: isEnabled,
                gainDB: gainDB,
                channels: channels
            )
        case .graphicEQ:
            return .graphicEQ(id: id, isEnabled: isEnabled, points: graphicEQPoints)
        case .convolution:
            return .convolution(id: id, isEnabled: isEnabled, ir: convolutionIR!)
        case .filter:
            return .filter(id: id, isEnabled: isEnabled, specification: filterSpecification!)
        }
    }
}

typealias M1PreampNode = M1ProcessingNode

enum M1ProcessingScopeResolver {
    static func effectiveSelections(
        nodes: [M1ProcessingNode]
    ) -> [UUID: M1ChannelSelection] {
        var result: [UUID: M1ChannelSelection] = [:]
        var current: M1ChannelSelection = .all
        for node in nodes {
            if node.kind == .channels {
                if node.isEnabled { current = node.channels }
            } else {
                result[node.id] = node.channels == .all ? current : node.channels
            }
        }
        return result
    }
}

enum M1SpeakerPosition: String, CaseIterable, Sendable {
    case left = "L"
    case right = "R"
    case center = "C"
    case lowFrequencyEffects = "LFE"
    case rearLeft = "RL"
    case rearRight = "RR"
    case rearCenter = "RC"
    case sideLeft = "SL"
    case sideRight = "SR"

    var channelIdentifier: M1ChannelIdentifier {
        M1ChannelIdentifier(rawValue)!
    }
}

struct M1OutputChannel: Equatable, Sendable {
    let linearIndex: Int
    let bufferIndex: Int
    let channelIndexInBuffer: Int
    let identifier: M1ChannelIdentifier
}

struct M1OutputLayoutSnapshot: Equatable, Sendable {
    let sampleRate: Double
    let maximumFrameCount: Int
    let bufferChannelCounts: [Int]
    let channels: [M1OutputChannel]

    init?(
        sampleRate: Double,
        maximumFrameCount: Int,
        bufferChannelCounts: [Int],
        semanticPositionsByChannelIndex: [M1SpeakerPosition?]
    ) {
        guard sampleRate.isFinite,
              sampleRate > 0,
              maximumFrameCount > 0,
              !bufferChannelCounts.isEmpty,
              bufferChannelCounts.allSatisfy({ $0 > 0 })
        else {
            return nil
        }

        var channelCount = 0
        for count in bufferChannelCounts {
            let result = channelCount.addingReportingOverflow(count)
            guard !result.overflow else {
                return nil
            }
            channelCount = result.partialValue
        }
        guard channelCount == semanticPositionsByChannelIndex.count else {
            return nil
        }

        let positionCounts = semanticPositionsByChannelIndex.reduce(
            into: [M1SpeakerPosition: Int]()
        ) { counts, position in
            if let position {
                counts[position, default: 0] += 1
            }
        }

        var resolvedChannels: [M1OutputChannel] = []
        resolvedChannels.reserveCapacity(channelCount)
        var linearIndex = 0
        for (bufferIndex, channelsInBuffer) in bufferChannelCounts.enumerated() {
            for channelIndexInBuffer in 0..<channelsInBuffer {
                let position = semanticPositionsByChannelIndex[linearIndex]
                let identifier: M1ChannelIdentifier
                if let position, positionCounts[position] == 1 {
                    identifier = position.channelIdentifier
                } else {
                    identifier = M1ChannelIdentifier(String(linearIndex + 1))!
                }
                resolvedChannels.append(
                    M1OutputChannel(
                        linearIndex: linearIndex,
                        bufferIndex: bufferIndex,
                        channelIndexInBuffer: channelIndexInBuffer,
                        identifier: identifier
                    )
                )
                linearIndex += 1
            }
        }

        self.sampleRate = sampleRate
        self.maximumFrameCount = maximumFrameCount
        self.bufferChannelCounts = bufferChannelCounts
        channels = resolvedChannels
    }
}

enum M1GraphicEQCSVCodecError: Error, Equatable {
    case invalidPoints
}

enum M1GraphicEQCSVCodec {
    static func decode(_ texts: [String]) throws -> [M1GraphicEQPoint] {
        let expression = try NSRegularExpression(
            pattern: #"[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?"#
        )
        var points: [M1GraphicEQPoint] = []
        for text in texts {
            for originalLine in text.components(separatedBy: .newlines)
                where !originalLine.hasPrefix("*") {
                let line = originalLine.contains(".")
                    ? originalLine : originalLine.replacingOccurrences(of: ",", with: ".")
                let range = NSRange(line.startIndex..., in: line)
                let values = expression.matches(in: line, range: range).compactMap { match in
                    Range(match.range, in: line).flatMap { Double(line[$0]) }
                }
                for index in stride(from: 0, to: values.count - 1, by: 2) {
                    points.append(M1GraphicEQPoint(
                        frequencyHz: values[index],
                        gainDB: values[index + 1]
                    ))
                }
            }
        }
        points.sort { $0.frequencyHz < $1.frequencyHz }
        guard points.count <= M1GraphicEQContract.maximumPointCount,
              points.allSatisfy({
                  $0.frequencyHz.isFinite && $0.gainDB.isFinite
                      && $0.frequencyHz > 0
                      && $0.gainDB >= M1GraphicEQContract.minimumGainDB
                      && $0.gainDB <= M1GraphicEQContract.maximumGainDB
              }),
              zip(points, points.dropFirst()).allSatisfy({
                  $0.frequencyHz < $1.frequencyHz
              }) else {
            throw M1GraphicEQCSVCodecError.invalidPoints
        }
        return points
    }

    static func encode(_ points: [M1GraphicEQPoint]) -> String {
        points.map { "\($0.frequencyHz)\t\($0.gainDB)" }
            .joined(separator: "\n") + "\n"
    }
}
