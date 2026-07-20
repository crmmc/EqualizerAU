import CoreAudio
import Foundation

struct BlackHoleDeviceSnapshot: Sendable {
    static let expectedUID = "BlackHole2ch_UID"
    static let expectedModelUID = "BlackHole2ch_ModelUID"
    static let expectedName = "BlackHole 2ch"
    static let expectedManufacturer = "Existential Audio Inc."

    let generation: AudioGeneration
    let objectID: AudioObjectID
    let uid: String
    let modelUID: String
    let name: String
    let manufacturer: String
    let transportType: UInt32
    let isAlive: Bool
    let isHidden: Bool
    let nominalSampleRate: Double
    let clockDomain: UInt32
    let inputLayout: AudioBufferLayout
    let outputLayout: AudioBufferLayout
    let inputFormat: AudioStreamBasicDescription
    let outputFormat: AudioStreamBasicDescription
}

enum BlackHoleDeviceDiscoveryError: Error, Equatable, LocalizedError, Sendable {
    case notInstalled(uid: String)
    case identityMismatch(field: String, expected: String, actual: String)
    case deviceNotAlive(uid: String)
    case invalidChannelLayout(input: UInt32, output: UInt32)
    case invalidFormat(scope: String, description: String)
    case invalidSampleRate(Double)

    var errorDescription: String? {
        switch self {
        case let .notInstalled(uid):
            return "Required virtual audio device '\(uid)' is not installed."
        case let .identityMismatch(field, expected, actual):
            return "BlackHole identity mismatch for \(field): expected '\(expected)', got '\(actual)'."
        case let .deviceNotAlive(uid):
            return "BlackHole device '\(uid)' is not alive."
        case let .invalidChannelLayout(input, output):
            return "BlackHole 2ch must expose two input and two output channels; got \(input)/\(output)."
        case let .invalidFormat(scope, description):
            return "BlackHole \(scope) format is unsupported: \(description)."
        case let .invalidSampleRate(sampleRate):
            return "BlackHole reported invalid nominal sample rate \(sampleRate)."
        }
    }
}

protocol BlackHoleDeviceDiscovering: Sendable {
    func snapshot(generation: AudioGeneration) async throws -> BlackHoleDeviceSnapshot
}

actor BlackHoleDeviceDiscovery: BlackHoleDeviceDiscovering {
    private let reader: HALPropertyReader

    init(reader: HALPropertyReader = HALPropertyReader()) {
        self.reader = reader
    }

    func snapshot(generation: AudioGeneration) throws -> BlackHoleDeviceSnapshot {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        let expectedUID = BlackHoleDeviceSnapshot.expectedUID
        let cfUID = expectedUID as CFString
        let deviceID: AudioObjectID = try reader.readQualifiedValue(
            objectID: systemObjectID,
            address: HALPropertyAddress(selector: kAudioHardwarePropertyTranslateUIDToDevice),
            operation: "Resolve BlackHole device UID",
            qualifier: cfUID,
            initialValue: kAudioObjectUnknown
        )
        guard deviceID != kAudioObjectUnknown else {
            throw BlackHoleDeviceDiscoveryError.notInstalled(uid: expectedUID)
        }

        let uid = try retainedString(deviceID, kAudioDevicePropertyDeviceUID, "Read BlackHole UID")
        let modelUID = try retainedString(deviceID, kAudioDevicePropertyModelUID, "Read BlackHole model UID")
        let name = try retainedString(deviceID, kAudioObjectPropertyName, "Read BlackHole name")
        let manufacturer = try retainedString(
            deviceID,
            kAudioObjectPropertyManufacturer,
            "Read BlackHole manufacturer"
        )
        try requireIdentity("UID", expectedUID, uid)
        try requireIdentity("model UID", BlackHoleDeviceSnapshot.expectedModelUID, modelUID)
        try requireIdentity("name", BlackHoleDeviceSnapshot.expectedName, name)
        try requireIdentity("manufacturer", BlackHoleDeviceSnapshot.expectedManufacturer, manufacturer)

        let transportType: UInt32 = try value(
            deviceID, kAudioDevicePropertyTransportType, "Read BlackHole transport type", 0
        )
        try requireIdentity(
            "transport",
            String(kAudioDeviceTransportTypeVirtual),
            String(transportType)
        )
        let alive: UInt32 = try value(
            deviceID, kAudioDevicePropertyDeviceIsAlive, "Read BlackHole alive state", 0
        )
        guard alive != 0 else {
            throw BlackHoleDeviceDiscoveryError.deviceNotAlive(uid: uid)
        }
        let hidden: UInt32 = try value(
            deviceID, kAudioDevicePropertyIsHidden, "Read BlackHole hidden state", 0
        )
        let sampleRate: Double = try value(
            deviceID, kAudioDevicePropertyNominalSampleRate, "Read BlackHole nominal sample rate", 0
        )
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw BlackHoleDeviceDiscoveryError.invalidSampleRate(sampleRate)
        }
        let clockDomain: UInt32 = try value(
            deviceID, kAudioDevicePropertyClockDomain, "Read BlackHole clock domain", 0
        )

        let inputLayout = try layout(deviceID: deviceID, scope: kAudioObjectPropertyScopeInput)
        let outputLayout = try layout(deviceID: deviceID, scope: kAudioObjectPropertyScopeOutput)
        guard inputLayout.totalChannelCount == 2, outputLayout.totalChannelCount == 2 else {
            throw BlackHoleDeviceDiscoveryError.invalidChannelLayout(
                input: inputLayout.totalChannelCount,
                output: outputLayout.totalChannelCount
            )
        }
        let inputFormat = try streamFormat(deviceID: deviceID, scope: kAudioObjectPropertyScopeInput)
        let outputFormat = try streamFormat(deviceID: deviceID, scope: kAudioObjectPropertyScopeOutput)
        try validate(format: inputFormat, scope: "input", sampleRate: sampleRate)
        try validate(format: outputFormat, scope: "output", sampleRate: sampleRate)

        return BlackHoleDeviceSnapshot(
            generation: generation,
            objectID: deviceID,
            uid: uid,
            modelUID: modelUID,
            name: name,
            manufacturer: manufacturer,
            transportType: transportType,
            isAlive: true,
            isHidden: hidden != 0,
            nominalSampleRate: sampleRate,
            clockDomain: clockDomain,
            inputLayout: inputLayout,
            outputLayout: outputLayout,
            inputFormat: inputFormat,
            outputFormat: outputFormat
        )
    }

    private func retainedString(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ operation: String
    ) throws -> String {
        try reader.readRetainedString(
            objectID: objectID,
            address: HALPropertyAddress(selector: selector),
            operation: operation
        )
    }

    private func value<Value>(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ operation: String,
        _ initialValue: Value,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> Value {
        try reader.readValue(
            objectID: objectID,
            address: HALPropertyAddress(selector: selector, scope: scope),
            operation: operation,
            initialValue: initialValue
        )
    }

    private func layout(
        deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) throws -> AudioBufferLayout {
        let data = try reader.readData(
            objectID: deviceID,
            address: HALPropertyAddress(
                selector: kAudioDevicePropertyStreamConfiguration,
                scope: scope
            ),
            operation: "Read BlackHole stream configuration"
        )
        do {
            return try AudioBufferLayout.parse(data)
        } catch {
            throw BlackHoleDeviceDiscoveryError.invalidChannelLayout(input: 0, output: 0)
        }
    }

    private func streamFormat(
        deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) throws -> AudioStreamBasicDescription {
        let data = try reader.readData(
            objectID: deviceID,
            address: HALPropertyAddress(selector: kAudioDevicePropertyStreams, scope: scope),
            operation: "Read BlackHole stream IDs"
        )
        guard data.count == MemoryLayout<AudioObjectID>.size else {
            throw BlackHoleDeviceDiscoveryError.invalidFormat(
                scope: scope == kAudioObjectPropertyScopeInput ? "input" : "output",
                description: "expected one stream object, got \(data.count) bytes"
            )
        }
        let streamID = data.withUnsafeBytes { bytes in
            bytes.loadUnaligned(as: AudioObjectID.self)
        }
        return try reader.readValue(
            objectID: streamID,
            address: HALPropertyAddress(selector: kAudioStreamPropertyVirtualFormat),
            operation: "Read BlackHole stream virtual format",
            initialValue: AudioStreamBasicDescription()
        )
    }

    private func requireIdentity(_ field: String, _ expected: String, _ actual: String) throws {
        guard actual == expected else {
            throw BlackHoleDeviceDiscoveryError.identityMismatch(
                field: field,
                expected: expected,
                actual: actual
            )
        }
    }

    private func validate(
        format: AudioStreamBasicDescription,
        scope: String,
        sampleRate: Double
    ) throws {
        let isSupported = format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            && format.mBitsPerChannel == 32
            && format.mChannelsPerFrame == 2
            && format.mFramesPerPacket == 1
            && format.mBytesPerFrame == UInt32(MemoryLayout<Float>.size * 2)
            && abs(format.mSampleRate - sampleRate) < 0.5
        guard isSupported else {
            throw BlackHoleDeviceDiscoveryError.invalidFormat(
                scope: scope,
                description: "rate=\(format.mSampleRate), format=\(fourCC(format.mFormatID)), flags=0x\(String(format.mFormatFlags, radix: 16)), bytes/frame=\(format.mBytesPerFrame), channels=\(format.mChannelsPerFrame), bits=\(format.mBitsPerChannel)"
            )
        }
    }
}
