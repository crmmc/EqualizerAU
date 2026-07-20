import CoreAudio
import XCTest
@testable import EqualizerAU

final class ProcessTapControllerTests: XCTestCase {
    func testCreateBuildsPrivateDeviceBoundTapExcludingCurrentProcess() async throws {
        let hal = ProcessTapHALStub(processObjectID: 901)
        let tapOperations = ProcessTapOperationsStub()
        let controller = ProcessTapController(
            propertyReader: HALPropertyReader(operations: hal),
            operations: tapOperations,
            processID: 1234
        )

        let resource = try await controller.create(
            configuration: ProcessTapConfiguration(
                generation: AudioGeneration(rawValue: 7),
                muteBehavior: .mutedWhenTapped,
                outputDeviceUID: "test-output-uid",
                outputStreamIndex: 0
            )
        )
        let captured = try XCTUnwrap(tapOperations.lastDescription)

        XCTAssertEqual(hal.translatedPID, 1234)
        XCTAssertEqual(resource.descriptor.generation, AudioGeneration(rawValue: 7))
        XCTAssertEqual(resource.objectID, 700)
        XCTAssertEqual(resource.uid, "test-tap-uid")
        XCTAssertEqual(resource.selfProcessObjectID, 901)
        XCTAssertEqual(resource.format.mSampleRate, 48_000)
        XCTAssertEqual(resource.format.mChannelsPerFrame, 2)
        XCTAssertEqual(resource.muteBehavior, .mutedWhenTapped)
        XCTAssertEqual(captured.processes, [901])
        XCTAssertTrue(captured.isExclusive)
        XCTAssertFalse(captured.isMixdown)
        XCTAssertFalse(captured.isMono)
        XCTAssertTrue(captured.isPrivate)
        XCTAssertEqual(captured.muteBehavior, .mutedWhenTapped)
        XCTAssertEqual(captured.deviceUID, "test-output-uid")
        XCTAssertEqual(captured.stream, 0)
        let translatedAgain = try await controller.currentProcessObjectID()
        XCTAssertEqual(translatedAgain, 901)

        try await controller.destroy(resource)
    }

    func testCreateBuildsPrivateDeviceBoundInclusiveTapWithoutSelf() async throws {
        let hal = ProcessTapHALStub(processObjectID: 901)
        let tapOperations = ProcessTapOperationsStub()
        let controller = ProcessTapController(
            propertyReader: HALPropertyReader(operations: hal),
            operations: tapOperations,
            processID: 1234
        )

        let resource = try await controller.create(
            configuration: ProcessTapConfiguration(
                generation: AudioGeneration(rawValue: 8),
                muteBehavior: .mutedWhenTapped,
                outputDeviceUID: "test-output-uid",
                outputStreamIndex: 0,
                includedProcessObjectIDs: [301, 302]
            )
        )
        let captured = try XCTUnwrap(tapOperations.lastDescription)

        XCTAssertEqual(captured.processes, [301, 302])
        XCTAssertFalse(captured.isExclusive)
        XCTAssertFalse(captured.isMixdown)
        XCTAssertTrue(captured.isPrivate)
        XCTAssertEqual(captured.muteBehavior, .mutedWhenTapped)
        XCTAssertEqual(captured.deviceUID, "test-output-uid")
        XCTAssertEqual(captured.stream, 0)
        XCTAssertFalse(captured.processes.contains(901))
        try await controller.destroy(resource)
    }

    func testInclusiveTapRejectsSelfInSourceSetBeforeCreate() async {
        let tapOperations = ProcessTapOperationsStub()
        let controller = makeController(tapOperations: tapOperations)

        do {
            _ = try await controller.create(
                configuration: ProcessTapConfiguration(
                    generation: AudioGeneration(rawValue: 1),
                    outputDeviceUID: "test-output-uid",
                    includedProcessObjectIDs: [901]
                )
            )
            XCTFail("Expected self-inclusive source set to fail")
        } catch {}

        XCTAssertNil(tapOperations.lastDescription)
    }

    func testGlobalScopeRemainsAvailableForMetadataProbe() async throws {
        let tapOperations = ProcessTapOperationsStub()
        let controller = makeController(tapOperations: tapOperations)

        let resource = try await controller.create(
            configuration: ProcessTapConfiguration(generation: AudioGeneration(rawValue: 1))
        )
        let captured = try XCTUnwrap(tapOperations.lastDescription)

        XCTAssertNil(captured.deviceUID)
        XCTAssertNil(captured.stream)
        try await controller.destroy(resource)
    }

    func testRepeatedDestroyFailsClosedAsStale() async throws {
        let tapOperations = ProcessTapOperationsStub()
        let controller = makeController(tapOperations: tapOperations)
        let resource = try await controller.create(
            configuration: ProcessTapConfiguration(generation: AudioGeneration(rawValue: 1))
        )

        try await controller.destroy(resource)
        do {
            try await controller.destroy(resource)
            XCTFail("Expected repeated destroy to reject the stale token")
        } catch let error as ProcessTapLifecycleError {
            XCTAssertEqual(error.status, kAudioHardwareBadObjectError)
        }

        XCTAssertEqual(tapOperations.destroyedTapIDs, [resource.objectID])
    }

    func testReusedHALObjectIDCannotBeDestroyedByOlderToken() async throws {
        let tapOperations = ProcessTapOperationsStub()
        let controller = makeController(tapOperations: tapOperations)
        let old = try await controller.create(
            configuration: ProcessTapConfiguration(generation: AudioGeneration(rawValue: 1))
        )
        try await controller.destroy(old)
        let current = try await controller.create(
            configuration: ProcessTapConfiguration(generation: AudioGeneration(rawValue: 2))
        )

        do {
            try await controller.destroy(old)
            XCTFail("Expected old ownership token to be rejected")
        } catch let error as ProcessTapLifecycleError {
            XCTAssertEqual(error.status, kAudioHardwareBadObjectError)
        }
        try await controller.destroy(current)

        XCTAssertEqual(tapOperations.destroyedTapIDs, [700, 700])
    }

    func testMetadataFailureDestroysCreatedTap() async {
        let hal = ProcessTapHALStub(
            processObjectID: 901,
            failingSelector: kAudioTapPropertyUID
        )
        let tapOperations = ProcessTapOperationsStub()
        let controller = ProcessTapController(
            propertyReader: HALPropertyReader(operations: hal),
            operations: tapOperations,
            processID: 1234
        )

        do {
            _ = try await controller.create(
                configuration: ProcessTapConfiguration(generation: AudioGeneration(rawValue: 1))
            )
            XCTFail("Expected tap metadata read to fail")
        } catch {
            XCTAssertEqual(tapOperations.destroyedTapIDs, [700])
        }
    }

    func testDestroyFailureCanBeRetried() async throws {
        let tapOperations = ProcessTapOperationsStub(destroyStatuses: [-50, noErr])
        let controller = makeController(tapOperations: tapOperations)
        let resource = try await controller.create(
            configuration: ProcessTapConfiguration(generation: AudioGeneration(rawValue: 1))
        )

        do {
            try await controller.destroy(resource)
            XCTFail("Expected first destroy to fail")
        } catch let error as ProcessTapLifecycleError {
            XCTAssertEqual(error.status, -50)
        }
        try await controller.destroy(resource)

        XCTAssertEqual(tapOperations.destroyedTapIDs, [700, 700])
    }

    func testMetadataFailureRetainsFailedRollbackForExplicitCleanup() async throws {
        let hal = ProcessTapHALStub(
            processObjectID: 901,
            failingSelector: kAudioTapPropertyUID
        )
        let tapOperations = ProcessTapOperationsStub(destroyStatuses: [-50, noErr])
        let controller = ProcessTapController(
            propertyReader: HALPropertyReader(operations: hal),
            operations: tapOperations,
            processID: 1234
        )

        do {
            _ = try await controller.create(
                configuration: ProcessTapConfiguration(generation: AudioGeneration(rawValue: 1))
            )
            XCTFail("Expected tap metadata read to fail")
        } catch {}

        try await controller.cleanupPendingCreation()
        XCTAssertEqual(tapOperations.destroyedTapIDs, [700, 700])
    }

    func testPendingRollbackTokenCannotDestroyReusedTapID() async throws {
        let hal = ProcessTapHALStub(
            processObjectID: 901,
            failingSelector: kAudioTapPropertyUID
        )
        let tapOperations = ProcessTapOperationsStub(destroyStatuses: [-50, noErr])
        let controller = ProcessTapController(
            propertyReader: HALPropertyReader(operations: hal),
            operations: tapOperations,
            processID: 1234
        )

        do {
            _ = try await controller.create(
                configuration: ProcessTapConfiguration(generation: AudioGeneration(rawValue: 1))
            )
            XCTFail("Expected first metadata read to fail")
        } catch {}

        let current = try await controller.create(
            configuration: ProcessTapConfiguration(generation: AudioGeneration(rawValue: 2))
        )
        try await controller.cleanupPendingCreation()
        try await controller.destroy(current)

        XCTAssertEqual(tapOperations.destroyedTapIDs, [700, 700])
    }

    func testDeviceBoundTapAcceptsNativeFloatMultichannelFormat() async throws {
        let hal = ProcessTapHALStub(processObjectID: 901, channelCount: 6)
        let tapOperations = ProcessTapOperationsStub()
        let controller = ProcessTapController(
            propertyReader: HALPropertyReader(operations: hal),
            operations: tapOperations,
            processID: 1234
        )

        let resource = try await controller.create(
            configuration: ProcessTapConfiguration(
                generation: AudioGeneration(rawValue: 12),
                outputDeviceUID: "test-output-uid"
            )
        )

        XCTAssertEqual(resource.format.mChannelsPerFrame, 6)
        XCTAssertEqual(resource.format.mBytesPerFrame, 24)
        try await controller.destroy(resource)
    }

    func testOutputStateReadsRunningFlagAndOwnedOutputDevices() async throws {
        let hal = ProcessTapHALStub(
            processObjectID: 901,
            runningOutput: true,
            outputDeviceIDs: [94, 42]
        )
        let controller = ProcessTapController(
            propertyReader: HALPropertyReader(operations: hal),
            operations: ProcessTapOperationsStub(),
            processID: 1234
        )

        let state = try await controller.outputState(processObjectID: 901)

        XCTAssertEqual(state, CoreAudioProcessOutputState(
            processObjectID: 901,
            isRunningOutput: true,
            outputDeviceIDs: [42, 94]
        ))
    }

    func testActiveOutputProcessesFiltersByRunningStateAndTargetDevice() async throws {
        let hal = ProcessTapHALStub(
            processObjectID: 901,
            processObjectIDs: [901, 902, 903, 904],
            runningOutputByObjectID: [901: true, 902: false, 903: true, 904: true],
            outputDeviceIDsByObjectID: [
                901: [94],
                902: [94],
                903: [42, 94],
                904: [42]
            ]
        )
        let controller = ProcessTapController(
            propertyReader: HALPropertyReader(operations: hal),
            operations: ProcessTapOperationsStub(),
            processID: 1234
        )

        let active = try await controller.activeOutputProcessObjectIDs(deviceID: 94)

        XCTAssertEqual(active, [901, 903])
    }

    private func makeController(
        tapOperations: ProcessTapOperationsStub
    ) -> ProcessTapController {
        ProcessTapController(
            propertyReader: HALPropertyReader(
                operations: ProcessTapHALStub(processObjectID: 901)
            ),
            operations: tapOperations,
            processID: 1234
        )
    }
}

private final class ProcessTapHALStub: @unchecked Sendable, HALPropertyOperations {
    private let processObjectID: AudioObjectID
    private let failingSelector: AudioObjectPropertySelector?
    private var remainingSelectorFailures: Int
    private let channelCount: UInt32
    private let runningOutput: Bool
    private let outputDeviceIDs: [AudioObjectID]
    private let processObjectIDs: [AudioObjectID]
    private let runningOutputByObjectID: [AudioObjectID: Bool]
    private let outputDeviceIDsByObjectID: [AudioObjectID: [AudioObjectID]]
    private let lock = NSLock()
    private var storedTranslatedPID: pid_t?

    var translatedPID: pid_t? {
        lock.withLock { storedTranslatedPID }
    }

    init(
        processObjectID: AudioObjectID,
        failingSelector: AudioObjectPropertySelector? = nil,
        channelCount: UInt32 = 2,
        runningOutput: Bool = false,
        outputDeviceIDs: [AudioObjectID] = [],
        processObjectIDs: [AudioObjectID] = [],
        runningOutputByObjectID: [AudioObjectID: Bool] = [:],
        outputDeviceIDsByObjectID: [AudioObjectID: [AudioObjectID]] = [:]
    ) {
        self.processObjectID = processObjectID
        self.failingSelector = failingSelector
        self.remainingSelectorFailures = failingSelector == nil ? 0 : 1
        self.channelCount = channelCount
        self.runningOutput = runningOutput
        self.outputDeviceIDs = outputDeviceIDs
        self.processObjectIDs = processObjectIDs
        self.runningOutputByObjectID = runningOutputByObjectID
        self.outputDeviceIDsByObjectID = outputDeviceIDsByObjectID
    }

    func propertyDataSize(
        objectID: AudioObjectID,
        address: HALPropertyAddress
    ) -> (status: OSStatus, size: UInt32) {
        if address.selector == kAudioHardwarePropertyProcessObjectList {
            return (noErr, UInt32(processObjectIDs.count * MemoryLayout<AudioObjectID>.size))
        }
        if address.selector == kAudioProcessPropertyDevices {
            let devices = outputDeviceIDsByObjectID[objectID] ?? outputDeviceIDs
            return (noErr, UInt32(devices.count * MemoryLayout<AudioObjectID>.size))
        }
        return (noErr, 0)
    }

    func propertyData(
        objectID: AudioObjectID,
        address: HALPropertyAddress,
        dataSize: inout UInt32,
        data: UnsafeMutableRawPointer
    ) -> OSStatus {
        if address.selector == failingSelector {
            let shouldFail = lock.withLock { () -> Bool in
                guard remainingSelectorFailures > 0 else { return false }
                remainingSelectorFailures -= 1
                return true
            }
            if shouldFail { return kAudio_ParamError }
        }
        switch address.selector {
        case kAudioTapPropertyUID:
            data.assumingMemoryBound(to: Optional<Unmanaged<CFString>>.self).pointee =
                Unmanaged.passRetained("test-tap-uid" as CFString)
            dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        case kAudioTapPropertyFormat:
            data.assumingMemoryBound(to: AudioStreamBasicDescription.self).pointee =
                AudioStreamBasicDescription(
                    mSampleRate: 48_000,
                    mFormatID: kAudioFormatLinearPCM,
                    mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
                    mBytesPerPacket: channelCount * 4,
                    mFramesPerPacket: 1,
                    mBytesPerFrame: channelCount * 4,
                    mChannelsPerFrame: channelCount,
                    mBitsPerChannel: 32,
                    mReserved: 0
                )
            dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        case kAudioProcessPropertyIsRunningOutput:
            let isRunning = runningOutputByObjectID[objectID] ?? runningOutput
            data.assumingMemoryBound(to: UInt32.self).pointee = isRunning ? 1 : 0
            dataSize = UInt32(MemoryLayout<UInt32>.size)
        case kAudioProcessPropertyDevices:
            let devices = outputDeviceIDsByObjectID[objectID] ?? outputDeviceIDs
            let required = devices.count * MemoryLayout<AudioObjectID>.size
            guard dataSize >= required else { return kAudio_ParamError }
            devices.withUnsafeBytes { bytes in
                if let source = bytes.baseAddress, required > 0 {
                    data.copyMemory(from: source, byteCount: required)
                }
            }
            dataSize = UInt32(required)
        case kAudioHardwarePropertyProcessObjectList:
            let required = processObjectIDs.count * MemoryLayout<AudioObjectID>.size
            guard dataSize >= required else { return kAudio_ParamError }
            processObjectIDs.withUnsafeBytes { bytes in
                if let source = bytes.baseAddress, required > 0 {
                    data.copyMemory(from: source, byteCount: required)
                }
            }
            dataSize = UInt32(required)
        default:
            return kAudio_ParamError
        }
        return noErr
    }

    func qualifiedPropertyData(
        objectID: AudioObjectID,
        address: HALPropertyAddress,
        qualifierDataSize: UInt32,
        qualifierData: UnsafeRawPointer,
        dataSize: inout UInt32,
        data: UnsafeMutableRawPointer
    ) -> OSStatus {
        guard address.selector == kAudioHardwarePropertyTranslatePIDToProcessObject,
              qualifierDataSize == MemoryLayout<pid_t>.size else {
            return kAudio_ParamError
        }
        let pid = qualifierData.load(as: pid_t.self)
        lock.withLock { storedTranslatedPID = pid }
        data.assumingMemoryBound(to: AudioObjectID.self).pointee = processObjectID
        dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        return noErr
    }
}

private final class ProcessTapOperationsStub: @unchecked Sendable, ProcessTapOperations {
    private let lock = NSLock()
    private var storedDescription: CATapDescription?
    private var storedDestroyedTapIDs: [AudioObjectID] = []
    private var destroyStatuses: [OSStatus]

    var lastDescription: CATapDescription? {
        lock.withLock { storedDescription }
    }

    var destroyedTapIDs: [AudioObjectID] {
        lock.withLock { storedDestroyedTapIDs }
    }

    init(destroyStatuses: [OSStatus] = []) {
        self.destroyStatuses = destroyStatuses
    }

    func create(description: CATapDescription, tapID: inout AudioObjectID) -> OSStatus {
        lock.withLock { storedDescription = description }
        tapID = 700
        return noErr
    }

    func destroy(tapID: AudioObjectID) -> OSStatus {
        lock.withLock {
            storedDestroyedTapIDs.append(tapID)
            return destroyStatuses.isEmpty ? noErr : destroyStatuses.removeFirst()
        }
    }
}
