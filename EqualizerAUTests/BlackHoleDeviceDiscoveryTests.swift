import CoreAudio
import XCTest
@testable import EqualizerAU

final class BlackHoleDeviceDiscoveryTests: XCTestCase {
    func testDiscoversAndValidatesExactBlackHole2chContract() async throws {
        let discovery = BlackHoleDeviceDiscovery(reader: HALPropertyReader(operations: BlackHoleHALStub()))

        let snapshot = try await discovery.snapshot(generation: AudioGeneration(rawValue: 7))

        XCTAssertEqual(snapshot.objectID, 700)
        XCTAssertEqual(snapshot.uid, BlackHoleDeviceSnapshot.expectedUID)
        XCTAssertEqual(snapshot.modelUID, BlackHoleDeviceSnapshot.expectedModelUID)
        XCTAssertEqual(snapshot.name, BlackHoleDeviceSnapshot.expectedName)
        XCTAssertEqual(snapshot.manufacturer, BlackHoleDeviceSnapshot.expectedManufacturer)
        XCTAssertEqual(snapshot.transportType, kAudioDeviceTransportTypeVirtual)
        XCTAssertTrue(snapshot.isAlive)
        XCTAssertFalse(snapshot.isHidden)
        XCTAssertEqual(snapshot.nominalSampleRate, 48_000)
        XCTAssertEqual(snapshot.inputLayout.totalChannelCount, 2)
        XCTAssertEqual(snapshot.outputLayout.totalChannelCount, 2)
        XCTAssertEqual(snapshot.inputFormat.mChannelsPerFrame, 2)
        XCTAssertEqual(snapshot.outputFormat.mBytesPerFrame, 8)
    }

    func testMissingDeviceFailsWithoutGuessingByName() async {
        let discovery = BlackHoleDeviceDiscovery(
            reader: HALPropertyReader(operations: BlackHoleHALStub(resolvedDeviceID: kAudioObjectUnknown))
        )

        do {
            _ = try await discovery.snapshot(generation: AudioGeneration(rawValue: 1))
            XCTFail("Expected missing BlackHole device to fail")
        } catch {
            XCTAssertEqual(
                error as? BlackHoleDeviceDiscoveryError,
                .notInstalled(uid: BlackHoleDeviceSnapshot.expectedUID)
            )
        }
    }

    func testIdentityMismatchFailsClosed() async {
        let discovery = BlackHoleDeviceDiscovery(
            reader: HALPropertyReader(operations: BlackHoleHALStub(manufacturer: "Unexpected Vendor"))
        )

        do {
            _ = try await discovery.snapshot(generation: AudioGeneration(rawValue: 1))
            XCTFail("Expected manufacturer mismatch")
        } catch {
            XCTAssertEqual(
                error as? BlackHoleDeviceDiscoveryError,
                .identityMismatch(
                    field: "manufacturer",
                    expected: BlackHoleDeviceSnapshot.expectedManufacturer,
                    actual: "Unexpected Vendor"
                )
            )
        }
    }
}

private final class BlackHoleHALStub: @unchecked Sendable, HALPropertyOperations {
    private let resolvedDeviceID: AudioObjectID
    private let manufacturer: String
    private let inputStreamID: AudioObjectID = 701
    private let outputStreamID: AudioObjectID = 702

    init(
        resolvedDeviceID: AudioObjectID = 700,
        manufacturer: String = BlackHoleDeviceSnapshot.expectedManufacturer
    ) {
        self.resolvedDeviceID = resolvedDeviceID
        self.manufacturer = manufacturer
    }

    func propertyDataSize(
        objectID: AudioObjectID,
        address: HALPropertyAddress
    ) -> (status: OSStatus, size: UInt32) {
        switch address.selector {
        case kAudioDevicePropertyStreamConfiguration:
            return (noErr, UInt32(MemoryLayout<AudioBufferList>.size))
        case kAudioDevicePropertyStreams:
            return (noErr, UInt32(MemoryLayout<AudioObjectID>.size))
        default:
            return (noErr, 0)
        }
    }

    func propertyData(
        objectID: AudioObjectID,
        address: HALPropertyAddress,
        dataSize: inout UInt32,
        data: UnsafeMutableRawPointer
    ) -> OSStatus {
        if objectID == 700 {
            switch address.selector {
            case kAudioDevicePropertyDeviceUID:
                return writeRetained(BlackHoleDeviceSnapshot.expectedUID, dataSize: &dataSize, data: data)
            case kAudioDevicePropertyModelUID:
                return writeRetained(BlackHoleDeviceSnapshot.expectedModelUID, dataSize: &dataSize, data: data)
            case kAudioObjectPropertyName:
                return writeRetained(BlackHoleDeviceSnapshot.expectedName, dataSize: &dataSize, data: data)
            case kAudioObjectPropertyManufacturer:
                return writeRetained(manufacturer, dataSize: &dataSize, data: data)
            case kAudioDevicePropertyTransportType:
                return write(kAudioDeviceTransportTypeVirtual, dataSize: &dataSize, data: data)
            case kAudioDevicePropertyDeviceIsAlive:
                return write(UInt32(1), dataSize: &dataSize, data: data)
            case kAudioDevicePropertyIsHidden:
                return write(UInt32(0), dataSize: &dataSize, data: data)
            case kAudioDevicePropertyNominalSampleRate:
                return write(Double(48_000), dataSize: &dataSize, data: data)
            case kAudioDevicePropertyClockDomain:
                return write(UInt32(0), dataSize: &dataSize, data: data)
            case kAudioDevicePropertyStreamConfiguration:
                return writeAudioBufferList(dataSize: &dataSize, data: data)
            case kAudioDevicePropertyStreams:
                let streamID = address.scope == kAudioObjectPropertyScopeInput
                    ? inputStreamID : outputStreamID
                return write(streamID, dataSize: &dataSize, data: data)
            default:
                return kAudio_ParamError
            }
        }
        if (objectID == inputStreamID || objectID == outputStreamID),
           address.selector == kAudioStreamPropertyVirtualFormat {
            return write(blackHoleFormat(), dataSize: &dataSize, data: data)
        }
        return kAudioHardwareBadObjectError
    }

    func qualifiedPropertyData(
        objectID: AudioObjectID,
        address: HALPropertyAddress,
        qualifierDataSize: UInt32,
        qualifierData: UnsafeRawPointer,
        dataSize: inout UInt32,
        data: UnsafeMutableRawPointer
    ) -> OSStatus {
        guard address.selector == kAudioHardwarePropertyTranslateUIDToDevice else {
            return kAudio_ParamError
        }
        return write(resolvedDeviceID, dataSize: &dataSize, data: data)
    }

    private func writeRetained(
        _ string: String,
        dataSize: inout UInt32,
        data: UnsafeMutableRawPointer
    ) -> OSStatus {
        let value = Unmanaged.passRetained(string as CFString)
        return write(Optional(value), dataSize: &dataSize, data: data)
    }

    private func write<Value>(
        _ value: Value,
        dataSize: inout UInt32,
        data: UnsafeMutableRawPointer
    ) -> OSStatus {
        data.assumingMemoryBound(to: Value.self).pointee = value
        dataSize = UInt32(MemoryLayout<Value>.size)
        return noErr
    }

    private func writeAudioBufferList(
        dataSize: inout UInt32,
        data: UnsafeMutableRawPointer
    ) -> OSStatus {
        let list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 0, mData: nil)
        )
        return write(list, dataSize: &dataSize, data: data)
    }

    private func blackHoleFormat() -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }
}
