import CoreAudio
import Foundation

struct ProcessTapProbeResult: Equatable, Sendable {
    let uid: String
    let sampleRate: Double
    let channelCount: UInt32
    let formatID: UInt32

    var formatDescription: String {
        let rate = sampleRate.formatted(
            .number.grouping(.never).precision(.fractionLength(0))
        )
        return "\(rate) Hz, \(channelCount) ch, \(fourCC(formatID))"
    }
}

protocol ProcessTapProbing: Sendable {
    func run() async throws -> ProcessTapProbeResult
}

struct ProcessTapProbeError: Error, Equatable, LocalizedError, Sendable {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        "\(operation) failed: OSStatus \(status) (\(fourCC(UInt32(bitPattern: status))))"
    }
}

actor ProcessTapProbe: ProcessTapProbing {
    private let controller: ProcessTapController

    init(controller: ProcessTapController = ProcessTapController()) {
        self.controller = controller
    }

    func run() async throws -> ProcessTapProbeResult {
        let resource = try await controller.create(
            configuration: ProcessTapConfiguration(
                generation: AudioGeneration(rawValue: 0),
                name: "EqualizerAU M0 Permission Probe",
                muteBehavior: .unmuted
            )
        )
        try await controller.destroy(resource)

        return ProcessTapProbeResult(
            uid: resource.uid,
            sampleRate: resource.format.mSampleRate,
            channelCount: resource.format.mChannelsPerFrame,
            formatID: resource.format.mFormatID
        )
    }
}
