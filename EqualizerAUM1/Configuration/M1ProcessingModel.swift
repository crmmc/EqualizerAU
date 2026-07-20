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

struct M1PreampNode: Identifiable, Equatable, Sendable {
    let id: UUID
    var isEnabled: Bool
    var gainDB: Double
    var channels: M1ChannelSelection
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
