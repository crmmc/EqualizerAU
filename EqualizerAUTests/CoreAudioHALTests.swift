import CoreAudio
import XCTest
@testable import EqualizerAU

final class CoreAudioHALTests: XCTestCase {
    func testReadsScalarRetainedStringASBDAndVariableData() throws {
        let operations = HALOperationsStub()
        let reader = HALPropertyReader(operations: operations)
        let objectID: AudioObjectID = 42

        let alive: UInt32 = try reader.readValue(
            objectID: objectID,
            address: HALPropertyAddress(selector: kAudioDevicePropertyDeviceIsAlive),
            operation: "Read alive",
            initialValue: 0
        )
        let uid = try reader.readRetainedString(
            objectID: objectID,
            address: HALPropertyAddress(selector: kAudioDevicePropertyDeviceUID),
            operation: "Read UID"
        )
        let format: AudioStreamBasicDescription = try reader.readValue(
            objectID: objectID,
            address: HALPropertyAddress(selector: kAudioTapPropertyFormat),
            operation: "Read format",
            initialValue: AudioStreamBasicDescription()
        )
        let streamConfiguration = try reader.readData(
            objectID: objectID,
            address: HALPropertyAddress(selector: kAudioDevicePropertyStreamConfiguration),
            operation: "Read stream configuration"
        )

        XCTAssertEqual(alive, 1)
        XCTAssertEqual(uid, "test-device-uid")
        XCTAssertEqual(format.mSampleRate, 48_000)
        XCTAssertEqual(format.mChannelsPerFrame, 2)
        XCTAssertEqual(streamConfiguration, Data([1, 2, 3, 4]))
    }

    func testReadFailureContainsObjectPropertyAndStatus() {
        let address = HALPropertyAddress(selector: kAudioDevicePropertyNominalSampleRate)
        let operations = HALOperationsStub(failingSelector: address.selector, failureStatus: -50)
        let reader = HALPropertyReader(operations: operations)

        XCTAssertThrowsError(
            try reader.readValue(
                objectID: 77,
                address: address,
                operation: "Read nominal sample rate",
                initialValue: Double.zero
            ) as Double
        ) { error in
            guard let error = error as? HALStatusError else {
                return XCTFail("Expected HALStatusError, got \(error)")
            }
            XCTAssertEqual(error.operation, "Read nominal sample rate")
            XCTAssertEqual(error.objectID, 77)
            XCTAssertEqual(error.address, address)
            XCTAssertEqual(error.status, -50)
            XCTAssertTrue(error.localizedDescription.contains("object 77"))
            XCTAssertTrue(error.localizedDescription.contains("selector="))
        }
    }

    func testVariableDataCanExplicitlyAllowEmptyPropertyLists() throws {
        let reader = HALPropertyReader(operations: HALOperationsStub())

        let data = try reader.readData(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: HALPropertyAddress(selector: kAudioHardwarePropertyTapList),
            operation: "Read empty tap list",
            allowEmpty: true
        )

        XCTAssertTrue(data.isEmpty)
    }

    func testListenerTokenCleanupIsIdempotent() throws {
        let counter = LockedCounter()
        let token = HALListenerToken(
            objectID: 9,
            address: HALPropertyAddress(selector: kAudioDevicePropertyDeviceIsAlive)
        ) {
            counter.increment()
            return noErr
        }

        try token.cancel()
        try token.cancel()

        XCTAssertEqual(counter.value, 1)
    }

    func testResourceDescriptorKeepsObjectIDScopedToGeneration() {
        let first = AudioResourceDescriptor(
            generation: AudioGeneration(rawValue: 1),
            kind: .aggregateDevice,
            objectID: 100,
            persistentUID: "aggregate-uid"
        )
        let second = AudioResourceDescriptor(
            generation: AudioGeneration(rawValue: 2),
            kind: .aggregateDevice,
            objectID: 100,
            persistentUID: "aggregate-uid"
        )

        XCTAssertNotEqual(first, second)
    }
}

private final class HALOperationsStub: @unchecked Sendable, HALPropertyOperations {
    private let failingSelector: AudioObjectPropertySelector?
    private let failureStatus: OSStatus

    init(
        failingSelector: AudioObjectPropertySelector? = nil,
        failureStatus: OSStatus = noErr
    ) {
        self.failingSelector = failingSelector
        self.failureStatus = failureStatus
    }

    func propertyDataSize(
        objectID: AudioObjectID,
        address: HALPropertyAddress
    ) -> (status: OSStatus, size: UInt32) {
        if address.selector == failingSelector {
            return (failureStatus, 0)
        }
        if address.selector == kAudioDevicePropertyStreamConfiguration {
            return (noErr, 4)
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
            return failureStatus
        }

        switch address.selector {
        case kAudioDevicePropertyDeviceIsAlive:
            data.assumingMemoryBound(to: UInt32.self).pointee = 1
            dataSize = UInt32(MemoryLayout<UInt32>.size)
        case kAudioDevicePropertyDeviceUID:
            let uid = Unmanaged.passRetained("test-device-uid" as CFString)
            data.assumingMemoryBound(to: Optional<Unmanaged<CFString>>.self).pointee = uid
            dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        case kAudioTapPropertyFormat:
            data.assumingMemoryBound(to: AudioStreamBasicDescription.self).pointee =
                AudioStreamBasicDescription(
                    mSampleRate: 48_000,
                    mFormatID: kAudioFormatLinearPCM,
                    mFormatFlags: 0,
                    mBytesPerPacket: 8,
                    mFramesPerPacket: 1,
                    mBytesPerFrame: 8,
                    mChannelsPerFrame: 2,
                    mBitsPerChannel: 32,
                    mReserved: 0
                )
            dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        case kAudioDevicePropertyStreamConfiguration:
            let bytes: [UInt8] = [1, 2, 3, 4]
            data.copyMemory(from: bytes, byteCount: bytes.count)
            dataSize = UInt32(bytes.count)
        default:
            return kAudio_ParamError
        }
        return noErr
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}
