import CoreAudio
import XCTest
@testable import EqualizerAU

final class AggregateDeviceControllerTests: XCTestCase {
    func testCreateBuildsPrivateTopologyAndReadsActualLayouts() async throws {
        let generation = AudioGeneration(rawValue: 9)
        let operations = AggregateOperationsStub()
        let hal = AggregateHALStub(
            aggregateUID: expectedAggregateUID(generation, prefix: "test.aggregate"),
            tapUIDs: ["test.tap"],
            inputChannels: [2],
            outputChannels: []
        )
        let controller = AggregateDeviceController(
            propertyReader: HALPropertyReader(operations: hal),
            propertyWriter: HALPropertyWriter(operations: hal),
            operations: operations
        )

        let resource = try await controller.create(
            configuration: AggregateDeviceConfiguration(
                generation: generation,
                uidPrefix: "test.aggregate"
            ),
            output: outputSnapshot(generation: generation),
            tap: tapResource(generation: generation)
        )
        let dictionary = try XCTUnwrap(operations.description as? [String: Any])
        let subTaps = try XCTUnwrap(
            dictionary[kAudioAggregateDeviceTapListKey] as? [[String: Any]]
        )

        XCTAssertEqual(resource.objectID, 800)
        XCTAssertEqual(resource.uid, expectedAggregateUID(generation, prefix: "test.aggregate"))
        XCTAssertEqual(resource.tapUIDs, ["test.tap"])
        XCTAssertEqual(resource.inputLayout.buffers, [.init(index: 0, channelCount: 2)])
        XCTAssertEqual(resource.nominalSampleRate, 48_000)
        XCTAssertEqual(resource.inputFormat.mChannelsPerFrame, 2)
        XCTAssertEqual(resource.maximumFrames, 4_096)
        XCTAssertEqual(dictionary[kAudioAggregateDeviceIsPrivateKey] as? Bool, true)
        XCTAssertEqual(dictionary[kAudioAggregateDeviceIsStackedKey] as? Bool, false)
        XCTAssertEqual(dictionary[kAudioAggregateDeviceTapAutoStartKey] as? Bool, false)
        XCTAssertNil(dictionary[kAudioAggregateDeviceMainSubDeviceKey])
        XCTAssertNil(dictionary[kAudioAggregateDeviceSubDeviceListKey])
        XCTAssertEqual(subTaps.first?[kAudioSubTapUIDKey] as? String, "test.tap")
        XCTAssertEqual(subTaps.first?[kAudioSubTapDriftCompensationKey] as? Bool, true)

        try await controller.destroy(resource)
    }

    func testGenerationMismatchFailsBeforeAggregateCreation() async {
        let operations = AggregateOperationsStub()
        let controller = AggregateDeviceController(operations: operations)

        do {
            _ = try await controller.create(
                configuration: AggregateDeviceConfiguration(
                    generation: AudioGeneration(rawValue: 2)
                ),
                output: outputSnapshot(generation: AudioGeneration(rawValue: 1)),
                tap: tapResource(generation: AudioGeneration(rawValue: 2))
            )
            XCTFail("Expected generation validation to fail")
        } catch {
            XCTAssertEqual(operations.createCount, 0)
        }
    }

    func testMissingTapInputDestroysCreatedAggregate() async {
        let generation = AudioGeneration(rawValue: 1)
        let operations = AggregateOperationsStub()
        let controller = AggregateDeviceController(
            propertyReader: HALPropertyReader(
                operations: AggregateHALStub(
                    aggregateUID: expectedAggregateUID(generation),
                    tapUIDs: ["test.tap"],
                    inputChannels: [],
                    outputChannels: []
                )
            ),
            propertyWriter: HALPropertyWriter(
                operations: AggregateHALStub(
                    aggregateUID: expectedAggregateUID(generation),
                    tapUIDs: ["test.tap"],
                    inputChannels: [],
                    outputChannels: []
                )
            ),
            operations: operations
        )

        do {
            _ = try await controller.create(
                configuration: AggregateDeviceConfiguration(generation: generation),
                output: outputSnapshot(generation: generation),
                tap: tapResource(generation: generation)
            )
            XCTFail("Expected tap input validation to fail")
        } catch let error as AggregateDeviceError {
            XCTAssertEqual(error, .missingInputChannels)
            XCTAssertEqual(operations.destroyedIDs, [800])
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDestroyFailureCanBeRetriedAndRepeatedDestroyIsStale() async throws {
        let generation = AudioGeneration(rawValue: 1)
        let operations = AggregateOperationsStub(destroyStatuses: [-50, noErr])
        let hal = AggregateHALStub(
            aggregateUID: expectedAggregateUID(generation),
            tapUIDs: ["test.tap"],
            inputChannels: [2],
            outputChannels: []
        )
        let controller = AggregateDeviceController(
            propertyReader: HALPropertyReader(operations: hal),
            propertyWriter: HALPropertyWriter(operations: hal),
            operations: operations
        )
        let resource = try await controller.create(
            configuration: AggregateDeviceConfiguration(generation: generation),
            output: outputSnapshot(generation: generation),
            tap: tapResource(generation: generation)
        )

        do {
            try await controller.destroy(resource)
            XCTFail("Expected first destroy to fail")
        } catch let error as AggregateDeviceError {
            XCTAssertEqual(error, .lifecycle(operation: "AudioHardwareDestroyAggregateDevice", status: -50))
        }
        try await controller.destroy(resource)
        do {
            try await controller.destroy(resource)
            XCTFail("Expected repeated destroy to reject the stale token")
        } catch let error as AggregateDeviceError {
            XCTAssertEqual(
                error,
                .lifecycle(operation: "Reject stale Aggregate Device resource", status: kAudioHardwareBadObjectError)
            )
        }

        XCTAssertEqual(operations.destroyedIDs, [800, 800])
    }

    func testReusedHALObjectIDCannotBeDestroyedByOlderToken() async throws {
        let generation = AudioGeneration(rawValue: 1)
        let operations = AggregateOperationsStub()
        let hal = AggregateHALStub(
            aggregateUID: expectedAggregateUID(generation),
            tapUIDs: ["test.tap"],
            inputChannels: [2],
            outputChannels: []
        )
        let controller = AggregateDeviceController(
            propertyReader: HALPropertyReader(operations: hal),
            propertyWriter: HALPropertyWriter(operations: hal),
            operations: operations
        )
        let old = try await controller.create(
            configuration: AggregateDeviceConfiguration(generation: generation),
            output: outputSnapshot(generation: generation),
            tap: tapResource(generation: generation)
        )
        try await controller.destroy(old)
        let current = try await controller.create(
            configuration: AggregateDeviceConfiguration(generation: generation),
            output: outputSnapshot(generation: generation),
            tap: tapResource(generation: generation)
        )

        do {
            try await controller.destroy(old)
            XCTFail("Expected old ownership token to be rejected")
        } catch let error as AggregateDeviceError {
            XCTAssertEqual(error, .lifecycle(
                operation: "Reject stale Aggregate Device resource",
                status: kAudioHardwareBadObjectError
            ))
        }
        try await controller.destroy(current)

        XCTAssertEqual(operations.destroyedIDs, [800, 800])
    }

    func testValidationFailureRetainsFailedRollbackForExplicitCleanup() async throws {
        let generation = AudioGeneration(rawValue: 1)
        let operations = AggregateOperationsStub(destroyStatuses: [-50, noErr])
        let hal = AggregateHALStub(
            aggregateUID: expectedAggregateUID(generation),
            tapUIDs: ["test.tap"],
            inputChannels: [],
            outputChannels: []
        )
        let controller = AggregateDeviceController(
            propertyReader: HALPropertyReader(operations: hal),
            propertyWriter: HALPropertyWriter(operations: hal),
            operations: operations
        )

        do {
            _ = try await controller.create(
                configuration: AggregateDeviceConfiguration(generation: generation),
                output: outputSnapshot(generation: generation),
                tap: tapResource(generation: generation)
            )
            XCTFail("Expected aggregate validation to fail")
        } catch {}

        try await controller.cleanupPendingCreation()
        XCTAssertEqual(operations.destroyedIDs, [800, 800])
    }

    func testPendingRollbackTokenCannotDestroyReusedAggregateID() async throws {
        let generation = AudioGeneration(rawValue: 1)
        let operations = AggregateOperationsStub(destroyStatuses: [-50, noErr])
        let hal = AggregateHALStub(
            aggregateUID: expectedAggregateUID(generation),
            aggregateUIDReads: ["wrong.uid", expectedAggregateUID(generation)],
            tapUIDs: ["test.tap"],
            inputChannels: [2],
            outputChannels: []
        )
        let controller = AggregateDeviceController(
            propertyReader: HALPropertyReader(operations: hal),
            propertyWriter: HALPropertyWriter(operations: hal),
            operations: operations
        )

        do {
            _ = try await controller.create(
                configuration: AggregateDeviceConfiguration(generation: generation),
                output: outputSnapshot(generation: generation),
                tap: tapResource(generation: generation)
            )
            XCTFail("Expected first UID validation to fail")
        } catch {}

        let current = try await controller.create(
            configuration: AggregateDeviceConfiguration(generation: generation),
            output: outputSnapshot(generation: generation),
            tap: tapResource(generation: generation)
        )
        try await controller.cleanupPendingCreation()
        try await controller.destroy(current)

        XCTAssertEqual(operations.destroyedIDs, [800, 800])
    }

    func testSuspendedRollbackCannotDestroyReusedAggregateID() async throws {
        let generation = AudioGeneration(rawValue: 1)
        let operations = AggregateOperationsStub()
        let hal = AggregateHALStub(
            aggregateUID: expectedAggregateUID(generation),
            tapUIDs: ["test.tap"],
            inputChannels: [2],
            outputChannels: [],
            nominalSampleRate: 44_100,
            ignoredNominalRateSetCount: 1
        )
        let controller = AggregateDeviceController(
            propertyReader: HALPropertyReader(operations: hal),
            propertyWriter: HALPropertyWriter(operations: hal),
            operations: operations
        )

        let oldCreation = Task {
            try await controller.create(
                configuration: AggregateDeviceConfiguration(generation: generation),
                output: outputSnapshot(generation: generation),
                tap: tapResource(generation: generation)
            )
        }
        await hal.waitUntilNominalRateSetCount(1)

        let current = try await controller.create(
            configuration: AggregateDeviceConfiguration(generation: generation),
            output: outputSnapshot(generation: generation),
            tap: tapResource(generation: generation)
        )
        oldCreation.cancel()
        do {
            _ = try await oldCreation.value
            XCTFail("Expected suspended creation to be cancelled")
        } catch is CancellationError {}

        try await controller.cleanupPendingCreation()
        try await controller.destroy(current)
        XCTAssertEqual(operations.destroyedIDs, [800])
    }

    func testNominalRateSetFailureUsesActualAggregateRateForOfflineAttribution() async throws {
        let generation = AudioGeneration(rawValue: 14)
        let operations = AggregateOperationsStub()
        let hal = AggregateHALStub(
            aggregateUID: expectedAggregateUID(generation),
            tapUIDs: ["test.tap"],
            inputChannels: [2],
            outputChannels: [],
            nominalSampleRate: 44_100,
            setNominalRateStatus: kAudioHardwareUnsupportedOperationError
        )
        let controller = AggregateDeviceController(
            propertyReader: HALPropertyReader(operations: hal),
            propertyWriter: HALPropertyWriter(operations: hal),
            operations: operations
        )

        let resource = try await controller.create(
            configuration: AggregateDeviceConfiguration(generation: generation),
            output: outputSnapshot(generation: generation),
            tap: tapResource(generation: generation)
        )

        XCTAssertEqual(resource.nominalSampleRate, 44_100)
        XCTAssertEqual(resource.inputFormat.mSampleRate, 44_100)
        try await controller.destroy(resource)
    }

    func testStreamConfigurationRejectsTotalChannelOverflow() throws {
        let data = streamConfiguration(channels: [UInt32.max, 1])

        XCTAssertThrowsError(try AudioBufferLayout.parse(data)) { error in
            XCTAssertEqual(error as? AggregateDeviceError, .malformedStreamConfiguration)
        }
    }
}

private func outputSnapshot(generation: AudioGeneration) -> AudioDeviceSnapshot {
    AudioDeviceSnapshot(
        generation: generation,
        objectID: 600,
        uid: "test.output",
        name: "Test Output",
        isAlive: true,
        nominalSampleRate: 48_000,
        outputChannelCount: 2,
        outputLayout: AudioBufferLayout(buffers: [.init(index: 0, channelCount: 2)]),
        bufferFrameSize: 512,
        bufferFrameSizeRange: 32...4096
    )
}

private func tapResource(generation: AudioGeneration) -> ProcessTapResource {
    ProcessTapResource(
        descriptor: AudioResourceDescriptor(
            generation: generation,
            kind: .processTap,
            objectID: 700,
            persistentUID: "test.tap"
        ),
        selfProcessObjectID: 901,
        format: AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        ),
        muteBehavior: .mutedWhenTapped
    )
}

private func expectedAggregateUID(
    _ generation: AudioGeneration,
    prefix: String = "com.ruimingchen.EqualizerAU.aggregate"
) -> String {
    "\(prefix).\(ProcessInfo.processInfo.processIdentifier).\(generation.rawValue)"
}

private final class AggregateOperationsStub: @unchecked Sendable, AggregateDeviceOperations {
    private let lock = NSLock()
    private var storedDescription: CFDictionary?
    private var storedDestroyedIDs: [AudioObjectID] = []
    private var storedCreateCount = 0
    private var destroyStatuses: [OSStatus]

    var description: CFDictionary? { lock.withLock { storedDescription } }
    var destroyedIDs: [AudioObjectID] { lock.withLock { storedDestroyedIDs } }
    var createCount: Int { lock.withLock { storedCreateCount } }

    init(destroyStatuses: [OSStatus] = []) {
        self.destroyStatuses = destroyStatuses
    }

    func create(description: CFDictionary, deviceID: inout AudioObjectID) -> OSStatus {
        lock.withLock {
            storedDescription = description
            storedCreateCount += 1
        }
        deviceID = 800
        return noErr
    }

    func destroy(deviceID: AudioObjectID) -> OSStatus {
        lock.withLock {
            storedDestroyedIDs.append(deviceID)
            return destroyStatuses.isEmpty ? noErr : destroyStatuses.removeFirst()
        }
    }
}

private final class AggregateHALStub: @unchecked Sendable, HALPropertyOperations {
    private let aggregateUID: String
    private var aggregateUIDReads: [String]
    private let tapUIDs: [String]
    private let inputData: Data
    private let outputData: Data
    private let lock = NSLock()
    private var nominalSampleRate: Double
    private let setNominalRateStatus: OSStatus
    private var ignoredNominalRateSetCount: Int
    private var nominalRateSetCount = 0

    init(
        aggregateUID: String,
        aggregateUIDReads: [String] = [],
        tapUIDs: [String],
        inputChannels: [UInt32],
        outputChannels: [UInt32],
        nominalSampleRate: Double = 48_000,
        setNominalRateStatus: OSStatus = noErr,
        ignoredNominalRateSetCount: Int = 0
    ) {
        self.aggregateUID = aggregateUID
        self.aggregateUIDReads = aggregateUIDReads
        self.tapUIDs = tapUIDs
        self.inputData = streamConfiguration(channels: inputChannels)
        self.outputData = streamConfiguration(channels: outputChannels)
        self.nominalSampleRate = nominalSampleRate
        self.setNominalRateStatus = setNominalRateStatus
        self.ignoredNominalRateSetCount = ignoredNominalRateSetCount
    }

    func propertyDataSize(
        objectID: AudioObjectID,
        address: HALPropertyAddress
    ) -> (status: OSStatus, size: UInt32) {
        guard address.selector == kAudioDevicePropertyStreamConfiguration else {
            return (kAudio_ParamError, 0)
        }
        let data = address.scope == kAudioObjectPropertyScopeInput ? inputData : outputData
        return (noErr, UInt32(data.count))
    }

    func propertyData(
        objectID: AudioObjectID,
        address: HALPropertyAddress,
        dataSize: inout UInt32,
        data: UnsafeMutableRawPointer
    ) -> OSStatus {
        switch address.selector {
        case kAudioDevicePropertyDeviceUID:
            let uid = lock.withLock {
                aggregateUIDReads.isEmpty ? aggregateUID : aggregateUIDReads.removeFirst()
            }
            return writeRetained(uid as CFString, dataSize: &dataSize, data: data)
        case kAudioAggregateDevicePropertyTapList:
            return writeRetained(tapUIDs as CFArray, dataSize: &dataSize, data: data)
        case kAudioDevicePropertyStreamConfiguration:
            let value = address.scope == kAudioObjectPropertyScopeInput ? inputData : outputData
            value.copyBytes(to: data.assumingMemoryBound(to: UInt8.self), count: value.count)
            dataSize = UInt32(value.count)
            return noErr
        case kAudioDevicePropertyNominalSampleRate:
            data.assumingMemoryBound(to: Double.self).pointee = lock.withLock {
                nominalSampleRate
            }
            dataSize = UInt32(MemoryLayout<Double>.size)
            return noErr
        case kAudioDevicePropertyStreamFormat:
            data.assumingMemoryBound(to: AudioStreamBasicDescription.self).pointee =
                AudioStreamBasicDescription(
                    mSampleRate: lock.withLock { nominalSampleRate },
                    mFormatID: kAudioFormatLinearPCM,
                    mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
                    mBytesPerPacket: 8,
                    mFramesPerPacket: 1,
                    mBytesPerFrame: 8,
                    mChannelsPerFrame: 2,
                    mBitsPerChannel: 32,
                    mReserved: 0
                )
            dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            return noErr
        case kAudioDevicePropertyBufferFrameSizeRange:
            data.assumingMemoryBound(to: AudioValueRange.self).pointee = AudioValueRange(
                mMinimum: 32,
                mMaximum: 4_096
            )
            dataSize = UInt32(MemoryLayout<AudioValueRange>.size)
            return noErr
        default:
            return kAudio_ParamError
        }
    }

    func setPropertyData(
        objectID: AudioObjectID,
        address: HALPropertyAddress,
        dataSize: UInt32,
        data: UnsafeRawPointer
    ) -> OSStatus {
        guard address.selector == kAudioDevicePropertyNominalSampleRate,
              dataSize == MemoryLayout<Double>.size else { return kAudio_ParamError }
        guard setNominalRateStatus == noErr else { return setNominalRateStatus }
        lock.withLock {
            nominalRateSetCount += 1
            if ignoredNominalRateSetCount > 0 {
                ignoredNominalRateSetCount -= 1
            } else {
                nominalSampleRate = data.load(as: Double.self)
            }
        }
        return noErr
    }

    func waitUntilNominalRateSetCount(_ expected: Int) async {
        while lock.withLock({ nominalRateSetCount < expected }) {
            await Task.yield()
        }
    }

    private func writeRetained<T: AnyObject>(
        _ value: T,
        dataSize: inout UInt32,
        data: UnsafeMutableRawPointer
    ) -> OSStatus {
        data.assumingMemoryBound(to: Optional<Unmanaged<T>>.self).pointee =
            Unmanaged.passRetained(value)
        dataSize = UInt32(MemoryLayout<Unmanaged<T>?>.size)
        return noErr
    }
}

private func streamConfiguration(channels: [UInt32]) -> Data {
    let offset = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers)!
    var data = Data(count: offset + channels.count * MemoryLayout<AudioBuffer>.stride)
    data.withUnsafeMutableBytes { bytes in
        bytes.storeBytes(of: UInt32(channels.count), as: UInt32.self)
        for (index, channelCount) in channels.enumerated() {
            bytes.storeBytes(
                of: AudioBuffer(mNumberChannels: channelCount, mDataByteSize: 0, mData: nil),
                toByteOffset: offset + index * MemoryLayout<AudioBuffer>.stride,
                as: AudioBuffer.self
            )
        }
    }
    return data
}
