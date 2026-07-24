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
    let storageID: UUID
    let originalFileName: String
    let sha256: String
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int
}

struct M1GraphicEQBand: Equatable, Sendable {
    let frequencyHz: Double
    var gainDB: Double
}

enum M1GraphicEQContract {
    static let minimumGainDB = -24.0
    static let maximumGainDB = 24.0
    static let gainStepDB = 0.1
    static let octaveBandwidth = 2.0 / 3.0
    static let centerFrequenciesHz: [Double] = [
        25, 40, 63, 100, 160, 250, 400, 630,
        1_000, 1_600, 2_500, 4_000, 6_300, 10_000, 16_000,
    ]

    static var flatBands: [M1GraphicEQBand] {
        centerFrequenciesHz.map { M1GraphicEQBand(frequencyHz: $0, gainDB: 0) }
    }
}

struct M1ProcessingNode: Identifiable, Equatable, Sendable {
    let id: UUID
    var kind: M1ProcessingNodeKind
    var isEnabled: Bool
    var gainDB: Double
    var channels: M1ChannelSelection
    var graphicEQBands: [M1GraphicEQBand]
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
        graphicEQBands = []
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
            graphicEQBands: [],
            convolutionIR: nil
        )
    }

    static func graphicEQ(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        bands: [M1GraphicEQBand] = M1GraphicEQContract.flatBands
    ) -> Self {
        Self(
            id: id,
            kind: .graphicEQ,
            isEnabled: isEnabled,
            gainDB: 0,
            channels: .all,
            graphicEQBands: bands,
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
            graphicEQBands: [],
            convolutionIR: ir
        )
    }

    private init(
        id: UUID,
        kind: M1ProcessingNodeKind,
        isEnabled: Bool,
        gainDB: Double,
        channels: M1ChannelSelection,
        graphicEQBands: [M1GraphicEQBand],
        convolutionIR: M1ConvolutionIRReference?
    ) {
        self.id = id
        self.kind = kind
        self.isEnabled = isEnabled
        self.gainDB = gainDB
        self.channels = channels
        self.graphicEQBands = graphicEQBands
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
            return .graphicEQ(id: id, isEnabled: isEnabled, bands: graphicEQBands)
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
