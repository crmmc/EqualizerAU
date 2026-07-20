import CoreAudio
import XCTest
@testable import EqualizerAU

final class CoreAudioProcessDiscoveryTests: XCTestCase {
    func testSnapshotIncludesOnlyRunningProcessesUsingTargetOutputAndExcludesSelf() async throws {
        let hal = CoreAudioProcessHALStub(
            selfProcessObjectID: 10,
            processObjectIDs: [10, 20, 30, 40],
            runningOutput: [10: true, 20: true, 30: false, 40: true],
            outputDevices: [10: [600], 20: [600], 30: [600], 40: [601]]
        )
        let discovery = CoreAudioProcessDiscovery(
            reader: HALPropertyReader(operations: hal),
            processID: 1234
        )

        let snapshot = try await discovery.snapshot(output: processOutputFixture())

        XCTAssertEqual(hal.translatedPID, 1234)
        XCTAssertEqual(snapshot.outputDeviceID, 600)
        XCTAssertEqual(snapshot.selfProcessObjectID, 10)
        XCTAssertEqual(snapshot.processObjectIDs, [20])
    }

    func testProcessThatDisappearsDuringEnumerationIsSkipped() async throws {
        let hal = CoreAudioProcessHALStub(
            selfProcessObjectID: 10,
            processObjectIDs: [20, 30],
            runningOutput: [20: true, 30: true],
            outputDevices: [20: [600]],
            disappearedProcessObjectIDs: [30]
        )
        let discovery = CoreAudioProcessDiscovery(
            reader: HALPropertyReader(operations: hal),
            processID: 1234
        )

        let snapshot = try await discovery.snapshot(output: processOutputFixture())

        XCTAssertEqual(snapshot.processObjectIDs, [20])
    }

    func testEmptyEligibleSetFailsBeforeMutedTapCanStart() async {
        let hal = CoreAudioProcessHALStub(
            selfProcessObjectID: 10,
            processObjectIDs: [10, 20],
            runningOutput: [10: true, 20: false],
            outputDevices: [10: [600], 20: [600]]
        )
        let discovery = CoreAudioProcessDiscovery(
            reader: HALPropertyReader(operations: hal),
            processID: 1234
        )

        do {
            _ = try await discovery.snapshot(output: processOutputFixture())
            XCTFail("Expected an empty source set to fail")
        } catch let error as CoreAudioProcessDiscoveryError {
            XCTAssertEqual(error, .noEligibleOutputProcesses(deviceUID: "test.output"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private final class CoreAudioProcessHALStub: @unchecked Sendable, HALPropertyOperations {
    let selfProcessObjectID: AudioObjectID
    let processObjectIDs: [AudioObjectID]
    let runningOutput: [AudioObjectID: Bool]
    let outputDevices: [AudioObjectID: [AudioObjectID]]
    let disappearedProcessObjectIDs: Set<AudioObjectID>
    private let lock = NSLock()
    private var storedTranslatedPID: pid_t?

    var translatedPID: pid_t? { lock.withLock { storedTranslatedPID } }

    init(
        selfProcessObjectID: AudioObjectID,
        processObjectIDs: [AudioObjectID],
        runningOutput: [AudioObjectID: Bool],
        outputDevices: [AudioObjectID: [AudioObjectID]],
        disappearedProcessObjectIDs: Set<AudioObjectID> = []
    ) {
        self.selfProcessObjectID = selfProcessObjectID
        self.processObjectIDs = processObjectIDs
        self.runningOutput = runningOutput
        self.outputDevices = outputDevices
        self.disappearedProcessObjectIDs = disappearedProcessObjectIDs
    }

    func propertyDataSize(
        objectID: AudioObjectID,
        address: HALPropertyAddress
    ) -> (status: OSStatus, size: UInt32) {
        switch address.selector {
        case kAudioHardwarePropertyProcessObjectList:
            return (noErr, UInt32(processObjectIDs.count * MemoryLayout<AudioObjectID>.size))
        case kAudioProcessPropertyDevices:
            if disappearedProcessObjectIDs.contains(objectID) {
                return (kAudioHardwareBadObjectError, 0)
            }
            return (noErr, UInt32(outputDevices[objectID, default: []].count * MemoryLayout<AudioObjectID>.size))
        default:
            return (kAudio_ParamError, 0)
        }
    }

    func propertyData(
        objectID: AudioObjectID,
        address: HALPropertyAddress,
        dataSize: inout UInt32,
        data: UnsafeMutableRawPointer
    ) -> OSStatus {
        if disappearedProcessObjectIDs.contains(objectID) {
            return kAudioHardwareBadObjectError
        }
        switch address.selector {
        case kAudioHardwarePropertyProcessObjectList:
            return copy(processObjectIDs, to: data, dataSize: &dataSize)
        case kAudioProcessPropertyIsRunningOutput:
            data.assumingMemoryBound(to: UInt32.self).pointee = runningOutput[objectID] == true ? 1 : 0
            dataSize = UInt32(MemoryLayout<UInt32>.size)
            return noErr
        case kAudioProcessPropertyDevices:
            return copy(outputDevices[objectID, default: []], to: data, dataSize: &dataSize)
        default:
            return kAudio_ParamError
        }
    }

    func qualifiedPropertyData(
        objectID: AudioObjectID,
        address: HALPropertyAddress,
        qualifierDataSize: UInt32,
        qualifierData: UnsafeRawPointer,
        dataSize: inout UInt32,
        data: UnsafeMutableRawPointer
    ) -> OSStatus {
        guard address.selector == kAudioHardwarePropertyTranslatePIDToProcessObject else {
            return kAudio_ParamError
        }
        lock.withLock { storedTranslatedPID = qualifierData.load(as: pid_t.self) }
        data.assumingMemoryBound(to: AudioObjectID.self).pointee = selfProcessObjectID
        dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        return noErr
    }

    private func copy(
        _ values: [AudioObjectID],
        to data: UnsafeMutableRawPointer,
        dataSize: inout UInt32
    ) -> OSStatus {
        values.withUnsafeBytes { bytes in
            if let baseAddress = bytes.baseAddress, !bytes.isEmpty {
                data.copyMemory(from: baseAddress, byteCount: bytes.count)
            }
            dataSize = UInt32(bytes.count)
        }
        return noErr
    }
}

private func processOutputFixture() -> AudioDeviceSnapshot {
    AudioDeviceSnapshot(
        generation: AudioGeneration(rawValue: 1),
        objectID: 600,
        uid: "test.output",
        name: "Test Output",
        isAlive: true,
        nominalSampleRate: 48_000,
        outputChannelCount: 2,
        outputLayout: AudioBufferLayout(buffers: [.init(index: 0, channelCount: 2)]),
        bufferFrameSize: 512,
        bufferFrameSizeRange: 32...4_096
    )
}
