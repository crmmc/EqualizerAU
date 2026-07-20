import CoreAudio
import Foundation

struct AudioBufferLayout: Equatable, Sendable {
    struct Buffer: Equatable, Sendable {
        let index: Int
        let channelCount: UInt32
    }

    let buffers: [Buffer]

    var totalChannelCount: UInt32 {
        let total = buffers.reduce(UInt64(0)) { $0 + UInt64($1.channelCount) }
        return UInt32(exactly: total) ?? 0
    }

    static func parse(_ data: Data) throws -> AudioBufferLayout {
        guard let firstBufferOffset = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers),
              data.count >= MemoryLayout<UInt32>.size,
              data.count >= firstBufferOffset
        else {
            throw AggregateDeviceError.malformedStreamConfiguration
        }

        return try data.withUnsafeBytes { bytes in
            let bufferCount = Int(bytes.loadUnaligned(as: UInt32.self))
            let (buffersSize, overflow) = bufferCount.multipliedReportingOverflow(
                by: MemoryLayout<AudioBuffer>.stride
            )
            guard !overflow,
                  buffersSize <= bytes.count - firstBufferOffset
            else {
                throw AggregateDeviceError.malformedStreamConfiguration
            }

            var buffers: [Buffer] = []
            buffers.reserveCapacity(bufferCount)
            var totalChannels: UInt32 = 0
            for index in 0..<bufferCount {
                let buffer = bytes.loadUnaligned(
                    fromByteOffset: firstBufferOffset + index * MemoryLayout<AudioBuffer>.stride,
                    as: AudioBuffer.self
                )
                let (newTotal, channelOverflow) = totalChannels.addingReportingOverflow(
                    buffer.mNumberChannels
                )
                guard !channelOverflow else {
                    throw AggregateDeviceError.malformedStreamConfiguration
                }
                totalChannels = newTotal
                buffers.append(Buffer(index: index, channelCount: buffer.mNumberChannels))
            }
            return AudioBufferLayout(buffers: buffers)
        }
    }
}

struct AggregateDeviceConfiguration: Equatable, Sendable {
    let generation: AudioGeneration
    let uid: String
    let name: String

    init(
        generation: AudioGeneration,
        uidPrefix: String = "com.ruimingchen.EqualizerAU.aggregate",
        name: String = "EqualizerAU Private Audio Path"
    ) {
        self.generation = generation
        self.uid = "\(uidPrefix).\(ProcessInfo.processInfo.processIdentifier).\(generation.rawValue)"
        self.name = name
    }
}

struct AggregateDeviceComposition: Equatable, Sendable {
    let uid: String
    let name: String
    let tapUID: String
    let tapDriftCompensation: Bool
    let isPrivate: Bool
    let isStacked: Bool
    let tapAutoStart: Bool

    var dictionary: CFDictionary {
        let subTap: [String: Any] = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: tapDriftCompensation,
        ]
        return [
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceIsPrivateKey: isPrivate,
            kAudioAggregateDeviceIsStackedKey: isStacked,
            kAudioAggregateDeviceTapListKey: [subTap],
            kAudioAggregateDeviceTapAutoStartKey: tapAutoStart,
        ] as CFDictionary
    }
}

struct AggregateDeviceResource: Sendable {
    let descriptor: AudioResourceDescriptor
    let outputDeviceUID: String
    let tapUID: String
    let tapUIDs: [String]
    let inputLayout: AudioBufferLayout
    let inputFormat: AudioStreamBasicDescription
    let nominalSampleRate: Double
    let maximumFrames: UInt32

    var objectID: AudioObjectID { descriptor.objectID }
    var uid: String { descriptor.persistentUID ?? "" }
    var ownershipToken: UUID { descriptor.ownershipToken }
}

enum AggregateDeviceError: Error, Equatable, LocalizedError, Sendable {
    case lifecycle(operation: String, status: OSStatus)
    case invalidInput(String)
    case tapListMismatch(expected: String, actual: [String])
    case malformedStreamConfiguration
    case missingInputChannels

    var errorDescription: String? {
        switch self {
        case let .lifecycle(operation, status):
            return "\(operation) failed: OSStatus \(status) (\(fourCC(UInt32(bitPattern: status))))"
        case let .invalidInput(reason):
            return "Invalid aggregate device input: \(reason)."
        case let .tapListMismatch(expected, actual):
            return "Aggregate tap list \(actual) does not contain exactly '\(expected)'."
        case .malformedStreamConfiguration:
            return "Aggregate device returned a malformed stream configuration."
        case .missingInputChannels:
            return "Aggregate device has no tap input channels."
        }
    }
}

protocol AggregateDeviceOperations: Sendable {
    func create(description: CFDictionary, deviceID: inout AudioObjectID) -> OSStatus
    func destroy(deviceID: AudioObjectID) -> OSStatus
}

protocol AggregateDeviceControlling: Sendable {
    func create(
        configuration: AggregateDeviceConfiguration,
        output: AudioDeviceSnapshot,
        tap: ProcessTapResource
    ) async throws -> AggregateDeviceResource
    func destroy(_ resource: AggregateDeviceResource) async throws
    func cleanupPendingCreation() async throws
}

struct SystemAggregateDeviceOperations: AggregateDeviceOperations {
    func create(description: CFDictionary, deviceID: inout AudioObjectID) -> OSStatus {
        AudioHardwareCreateAggregateDevice(description, &deviceID)
    }

    func destroy(deviceID: AudioObjectID) -> OSStatus {
        AudioHardwareDestroyAggregateDevice(deviceID)
    }
}

actor AggregateDeviceController: AggregateDeviceControlling {
    private let propertyReader: HALPropertyReader
    private let propertyWriter: HALPropertyWriter
    private let operations: any AggregateDeviceOperations
    private var activeDeviceTokens: [AudioObjectID: UUID] = [:]
    private var pendingCreationDeviceTokens: [AudioObjectID: UUID] = [:]

    init(
        propertyReader: HALPropertyReader = HALPropertyReader(),
        propertyWriter: HALPropertyWriter = HALPropertyWriter(),
        operations: any AggregateDeviceOperations = SystemAggregateDeviceOperations()
    ) {
        self.propertyReader = propertyReader
        self.propertyWriter = propertyWriter
        self.operations = operations
    }

    func create(
        configuration: AggregateDeviceConfiguration,
        output: AudioDeviceSnapshot,
        tap: ProcessTapResource
    ) async throws -> AggregateDeviceResource {
        guard configuration.generation == output.generation,
              configuration.generation == tap.descriptor.generation
        else {
            throw AggregateDeviceError.invalidInput("resource generations do not match")
        }
        guard !configuration.uid.isEmpty, !output.uid.isEmpty, !tap.uid.isEmpty else {
            throw AggregateDeviceError.invalidInput("UID is empty")
        }

        let composition = AggregateDeviceComposition(
            uid: configuration.uid,
            name: configuration.name,
            tapUID: tap.uid,
            tapDriftCompensation: true,
            isPrivate: true,
            isStacked: false,
            tapAutoStart: false
        )
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = operations.create(
            description: composition.dictionary,
            deviceID: &aggregateID
        )
        guard status == noErr, aggregateID != kAudioObjectUnknown else {
            throw AggregateDeviceError.lifecycle(
                operation: "AudioHardwareCreateAggregateDevice",
                status: status == noErr ? kAudioHardwareBadObjectError : status
            )
        }
        let ownershipToken = UUID()
        activeDeviceTokens[aggregateID] = ownershipToken

        do {
            let uid = try propertyReader.readRetainedString(
                objectID: aggregateID,
                address: HALPropertyAddress(selector: kAudioDevicePropertyDeviceUID),
                operation: "Read aggregate device UID"
            )
            guard uid == configuration.uid else {
                throw AggregateDeviceError.invalidInput("HAL returned an unexpected aggregate UID")
            }
            let tapUIDs = try propertyReader.readRetainedStringArray(
                objectID: aggregateID,
                address: HALPropertyAddress(selector: kAudioAggregateDevicePropertyTapList),
                operation: "Read aggregate tap UID list"
            )
            guard tapUIDs == [tap.uid] else {
                throw AggregateDeviceError.tapListMismatch(expected: tap.uid, actual: tapUIDs)
            }

            let targetSampleRate = min(output.nominalSampleRate, tap.format.mSampleRate)
            let nominalSampleRate = try await configureNominalSampleRate(
                aggregateID: aggregateID,
                target: targetSampleRate
            )

            let inputLayout = try readLayout(
                aggregateID: aggregateID,
                scope: kAudioObjectPropertyScopeInput,
                operation: "Read aggregate input stream configuration"
            )
            guard inputLayout.totalChannelCount > 0 else {
                throw AggregateDeviceError.missingInputChannels
            }
            guard inputLayout.buffers.allSatisfy({ $0.channelCount > 0 }) else {
                throw AggregateDeviceError.invalidInput("aggregate reported an empty input buffer")
            }
            let inputFormat: AudioStreamBasicDescription = try propertyReader.readValue(
                objectID: aggregateID,
                address: HALPropertyAddress(
                    selector: kAudioDevicePropertyStreamFormat,
                    scope: kAudioObjectPropertyScopeInput
                ),
                operation: "Read aggregate input stream format",
                initialValue: AudioStreamBasicDescription()
            )
            guard isSupportedInputFormat(
                inputFormat,
                channelCount: inputLayout.totalChannelCount,
                sampleRate: nominalSampleRate
            ) else {
                throw AggregateDeviceError.invalidInput(
                    "aggregate input is not packed native Float32 at the configured rate"
                )
            }
            let frameRange: AudioValueRange = try propertyReader.readValue(
                objectID: aggregateID,
                address: HALPropertyAddress(selector: kAudioDevicePropertyBufferFrameSizeRange),
                operation: "Read aggregate buffer frame-size range",
                initialValue: AudioValueRange()
            )
            guard frameRange.mMaximum.isFinite,
                  frameRange.mMaximum > 0,
                  frameRange.mMaximum <= Double(UInt32.max) else {
                throw AggregateDeviceError.invalidInput("invalid aggregate frame-size range")
            }
            return AggregateDeviceResource(
                descriptor: AudioResourceDescriptor(
                    ownershipToken: ownershipToken,
                    generation: configuration.generation,
                    kind: .aggregateDevice,
                    objectID: aggregateID,
                    persistentUID: uid
                ),
                outputDeviceUID: output.uid,
                tapUID: tap.uid,
                tapUIDs: tapUIDs,
                inputLayout: inputLayout,
                inputFormat: inputFormat,
                nominalSampleRate: nominalSampleRate,
                maximumFrames: UInt32(frameRange.mMaximum.rounded(.up))
            )
        } catch {
            do {
                try destroy(deviceID: aggregateID, ownershipToken: ownershipToken)
            } catch {
                if activeDeviceTokens[aggregateID] == ownershipToken {
                    pendingCreationDeviceTokens[aggregateID] = ownershipToken
                }
            }
            throw error
        }
    }

    func destroy(_ resource: AggregateDeviceResource) throws {
        guard activeDeviceTokens[resource.objectID] == resource.ownershipToken else {
            throw AggregateDeviceError.lifecycle(
                operation: "Reject stale Aggregate Device resource",
                status: kAudioHardwareBadObjectError
            )
        }
        try destroy(deviceID: resource.objectID, ownershipToken: resource.ownershipToken)
    }

    private func destroy(deviceID: AudioObjectID, ownershipToken: UUID) throws {
        guard activeDeviceTokens[deviceID] == ownershipToken else {
            throw AggregateDeviceError.lifecycle(
                operation: "Reject stale Aggregate Device resource",
                status: kAudioHardwareBadObjectError
            )
        }
        let status = operations.destroy(deviceID: deviceID)
        guard status == noErr else {
            throw AggregateDeviceError.lifecycle(
                operation: "AudioHardwareDestroyAggregateDevice",
                status: status
            )
        }
        activeDeviceTokens.removeValue(forKey: deviceID)
        pendingCreationDeviceTokens.removeValue(forKey: deviceID)
    }

    func cleanupPendingCreation() async throws {
        for deviceID in pendingCreationDeviceTokens.keys.sorted() {
            guard let pendingToken = pendingCreationDeviceTokens[deviceID] else { continue }
            guard activeDeviceTokens[deviceID] == pendingToken else {
                pendingCreationDeviceTokens.removeValue(forKey: deviceID)
                continue
            }
            try destroy(deviceID: deviceID, ownershipToken: pendingToken)
        }
    }

    private func readLayout(
        aggregateID: AudioObjectID,
        scope: AudioObjectPropertyScope,
        operation: String
    ) throws -> AudioBufferLayout {
        let data = try propertyReader.readData(
            objectID: aggregateID,
            address: HALPropertyAddress(
                selector: kAudioDevicePropertyStreamConfiguration,
                scope: scope
            ),
            operation: operation
        )
        return try AudioBufferLayout.parse(data)
    }

    private func configureNominalSampleRate(
        aggregateID: AudioObjectID,
        target: Double
    ) async throws -> Double {
        let address = HALPropertyAddress(selector: kAudioDevicePropertyNominalSampleRate)
        let current = try readNominalSampleRate(aggregateID: aggregateID, address: address)
        if abs(current - target) < 0.5 { return current }

        do {
            try propertyWriter.writeValue(
                target,
                objectID: aggregateID,
                address: address,
                operation: "Set aggregate nominal sample rate"
            )
        } catch {
            return try readNominalSampleRate(aggregateID: aggregateID, address: address)
        }

        for attempt in 0..<50 {
            let actual = try readNominalSampleRate(aggregateID: aggregateID, address: address)
            if abs(actual - target) < 0.5 { return actual }
            if attempt < 49 { try await Task.sleep(for: .milliseconds(10)) }
        }
        return try readNominalSampleRate(aggregateID: aggregateID, address: address)
    }

    private func readNominalSampleRate(
        aggregateID: AudioObjectID,
        address: HALPropertyAddress
    ) throws -> Double {
        let actual: Double = try propertyReader.readValue(
            objectID: aggregateID,
            address: address,
            operation: "Read aggregate nominal sample rate",
            initialValue: 0
        )
        guard actual.isFinite, actual > 0 else {
            throw AggregateDeviceError.invalidInput("invalid aggregate nominal sample rate")
        }
        return actual
    }

    private func isSupportedInputFormat(
        _ format: AudioStreamBasicDescription,
        channelCount: UInt32,
        sampleRate: Double
    ) -> Bool {
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let (interleavedBytesPerFrame, overflow) = UInt32(MemoryLayout<Float>.size)
            .multipliedReportingOverflow(by: channelCount)
        guard !overflow else { return false }
        let expectedBytesPerFrame = nonInterleaved
            ? UInt32(MemoryLayout<Float>.size)
            : interleavedBytesPerFrame
        return format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mFramesPerPacket == 1
            && format.mChannelsPerFrame == channelCount
            && format.mBitsPerChannel == 32
            && format.mBytesPerFrame == expectedBytesPerFrame
            && format.mBytesPerPacket == expectedBytesPerFrame
            && abs(format.mSampleRate - sampleRate) < 0.5
    }
}
