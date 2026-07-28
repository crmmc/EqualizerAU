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

struct M1ProcessingNode: Identifiable, Equatable, Sendable {
    let id: UUID
    var kind: M1ProcessingNodeKind
    var isEnabled: Bool
    var gainDB: Double
    var channels: M1ChannelSelection
    var graphicEQPoints: [M1GraphicEQPoint]
    var convolutionIR: M1ConvolutionIRReference?

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

    private init(
        id: UUID,
        kind: M1ProcessingNodeKind,
        isEnabled: Bool,
        gainDB: Double,
        channels: M1ChannelSelection,
        graphicEQPoints: [M1GraphicEQPoint],
        convolutionIR: M1ConvolutionIRReference?
    ) {
        self.id = id
        self.kind = kind
        self.isEnabled = isEnabled
        self.gainDB = gainDB
        self.channels = channels
        self.graphicEQPoints = graphicEQPoints
        self.convolutionIR = convolutionIR
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
