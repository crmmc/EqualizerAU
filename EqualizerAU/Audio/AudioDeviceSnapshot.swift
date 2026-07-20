import CoreAudio
import Foundation

struct AudioDeviceSnapshot: Equatable, Sendable {
    let generation: AudioGeneration
    let objectID: AudioObjectID
    let uid: String
    let name: String
    let isAlive: Bool
    let nominalSampleRate: Double
    let outputChannelCount: UInt32
    let outputLayout: AudioBufferLayout
    let bufferFrameSize: UInt32
    let bufferFrameSizeRange: ClosedRange<Double>

    var displayDescription: String {
        let sampleRate = nominalSampleRate.formatted(
            .number.grouping(.never).precision(.fractionLength(0))
        )
        return "\(name) (\(sampleRate) Hz, \(outputChannelCount) ch)"
    }
}

enum AudioDeviceSnapshotError: Error, Equatable, LocalizedError, Sendable {
    case noDefaultOutputDevice
    case deviceNotAlive(uid: String)
    case invalidSampleRate(Double)
    case noOutputChannels(uid: String)
    case malformedStreamConfiguration
    case invalidBufferFrameSizeRange(minimum: Double, maximum: Double)
    case bufferFrameSizeOutsideRange(current: UInt32, minimum: Double, maximum: Double)

    var errorDescription: String? {
        switch self {
        case .noDefaultOutputDevice:
            return "Core Audio did not report a default output device."
        case let .deviceNotAlive(uid):
            return "Default output device '\(uid)' is not alive."
        case let .invalidSampleRate(sampleRate):
            return "Default output device reported invalid sample rate \(sampleRate)."
        case let .noOutputChannels(uid):
            return "Default output device '\(uid)' has no output channels."
        case .malformedStreamConfiguration:
            return "Default output device returned a malformed stream configuration."
        case let .invalidBufferFrameSizeRange(minimum, maximum):
            return "Default output device reported invalid buffer frame range \(minimum)...\(maximum)."
        case let .bufferFrameSizeOutsideRange(current, minimum, maximum):
            return "Buffer frame size \(current) is outside the supported range \(minimum)...\(maximum)."
        }
    }
}

protocol DefaultOutputDeviceDiscovering: Sendable {
    func snapshot(generation: AudioGeneration) async throws -> AudioDeviceSnapshot
}

actor DefaultOutputDeviceDiscovery: DefaultOutputDeviceDiscovering {
    private let reader: HALPropertyReader

    init(reader: HALPropertyReader = HALPropertyReader()) {
        self.reader = reader
    }

    func snapshot(generation: AudioGeneration) throws -> AudioDeviceSnapshot {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        let deviceID: AudioObjectID = try reader.readValue(
            objectID: systemObjectID,
            address: HALPropertyAddress(selector: kAudioHardwarePropertyDefaultOutputDevice),
            operation: "Read default output device",
            initialValue: kAudioObjectUnknown
        )
        guard deviceID != kAudioObjectUnknown else {
            throw AudioDeviceSnapshotError.noDefaultOutputDevice
        }

        let uid = try reader.readRetainedString(
            objectID: deviceID,
            address: HALPropertyAddress(selector: kAudioDevicePropertyDeviceUID),
            operation: "Read output device UID"
        )
        let name = try reader.readRetainedString(
            objectID: deviceID,
            address: HALPropertyAddress(selector: kAudioObjectPropertyName),
            operation: "Read output device name"
        )
        let alive: UInt32 = try reader.readValue(
            objectID: deviceID,
            address: HALPropertyAddress(selector: kAudioDevicePropertyDeviceIsAlive),
            operation: "Read output device alive state",
            initialValue: 0
        )
        guard alive != 0 else {
            throw AudioDeviceSnapshotError.deviceNotAlive(uid: uid)
        }

        let sampleRate: Double = try reader.readValue(
            objectID: deviceID,
            address: HALPropertyAddress(selector: kAudioDevicePropertyNominalSampleRate),
            operation: "Read output device nominal sample rate",
            initialValue: 0
        )
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw AudioDeviceSnapshotError.invalidSampleRate(sampleRate)
        }

        let streamConfiguration = try reader.readData(
            objectID: deviceID,
            address: HALPropertyAddress(
                selector: kAudioDevicePropertyStreamConfiguration,
                scope: kAudioObjectPropertyScopeOutput
            ),
            operation: "Read output device stream configuration"
        )
        let outputLayout: AudioBufferLayout
        do {
            outputLayout = try AudioBufferLayout.parse(streamConfiguration)
        } catch {
            throw AudioDeviceSnapshotError.malformedStreamConfiguration
        }
        let channelCount = outputLayout.totalChannelCount
        guard channelCount > 0 else {
            throw AudioDeviceSnapshotError.noOutputChannels(uid: uid)
        }

        let frameSize: UInt32 = try reader.readValue(
            objectID: deviceID,
            address: HALPropertyAddress(selector: kAudioDevicePropertyBufferFrameSize),
            operation: "Read output device buffer frame size",
            initialValue: 0
        )
        let frameRange: AudioValueRange = try reader.readValue(
            objectID: deviceID,
            address: HALPropertyAddress(selector: kAudioDevicePropertyBufferFrameSizeRange),
            operation: "Read output device buffer frame size range",
            initialValue: AudioValueRange()
        )
        guard frameRange.mMinimum.isFinite,
              frameRange.mMaximum.isFinite,
              frameRange.mMinimum > 0,
              frameRange.mMinimum <= frameRange.mMaximum
        else {
            throw AudioDeviceSnapshotError.invalidBufferFrameSizeRange(
                minimum: frameRange.mMinimum,
                maximum: frameRange.mMaximum
            )
        }
        guard frameRange.mMinimum...frameRange.mMaximum ~= Double(frameSize) else {
            throw AudioDeviceSnapshotError.bufferFrameSizeOutsideRange(
                current: frameSize,
                minimum: frameRange.mMinimum,
                maximum: frameRange.mMaximum
            )
        }

        return AudioDeviceSnapshot(
            generation: generation,
            objectID: deviceID,
            uid: uid,
            name: name,
            isAlive: true,
            nominalSampleRate: sampleRate,
            outputChannelCount: channelCount,
            outputLayout: outputLayout,
            bufferFrameSize: frameSize,
            bufferFrameSizeRange: frameRange.mMinimum...frameRange.mMaximum
        )
    }

}
