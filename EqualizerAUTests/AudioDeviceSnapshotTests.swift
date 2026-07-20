import CoreAudio
import XCTest
@testable import EqualizerAU

final class AudioDeviceSnapshotTests: XCTestCase {
    func testReadsCompleteDefaultOutputSnapshot() async throws {
        let discovery = DefaultOutputDeviceDiscovery(
            reader: HALPropertyReader(operations: DeviceOperationsStub())
        )
        let generation = AudioGeneration(rawValue: 7)

        let snapshot = try await discovery.snapshot(generation: generation)

        XCTAssertEqual(snapshot.generation, generation)
        XCTAssertEqual(snapshot.objectID, 42)
        XCTAssertEqual(snapshot.uid, "test-output-uid")
        XCTAssertEqual(snapshot.name, "Test Output")
        XCTAssertTrue(snapshot.isAlive)
        XCTAssertEqual(snapshot.nominalSampleRate, 48_000)
        XCTAssertEqual(snapshot.outputChannelCount, 2)
        XCTAssertEqual(snapshot.bufferFrameSize, 512)
        XCTAssertEqual(snapshot.bufferFrameSizeRange, 32...4_096)
        XCTAssertEqual(snapshot.displayDescription, "Test Output (48000 Hz, 2 ch)")
    }

    func testRejectsDeviceWithoutOutputChannelsBeforeTapCreation() async {
        let discovery = DefaultOutputDeviceDiscovery(
            reader: HALPropertyReader(
                operations: DeviceOperationsStub(outputChannelCount: 0)
            )
        )

        do {
            _ = try await discovery.snapshot(generation: AudioGeneration(rawValue: 1))
            XCTFail("Expected output-channel validation failure")
        } catch {
            XCTAssertEqual(
                error as? AudioDeviceSnapshotError,
                .noOutputChannels(uid: "test-output-uid")
            )
        }
    }

    func testRejectsMalformedStreamConfiguration() async {
        let discovery = DefaultOutputDeviceDiscovery(
            reader: HALPropertyReader(
                operations: DeviceOperationsStub(malformedStreamConfiguration: true)
            )
        )

        do {
            _ = try await discovery.snapshot(generation: AudioGeneration(rawValue: 1))
            XCTFail("Expected malformed stream configuration failure")
        } catch {
            XCTAssertEqual(error as? AudioDeviceSnapshotError, .malformedStreamConfiguration)
        }
    }

    func testObjectIDIsBoundToSnapshotGeneration() async throws {
        let discovery = DefaultOutputDeviceDiscovery(
            reader: HALPropertyReader(operations: DeviceOperationsStub())
        )

        let first = try await discovery.snapshot(generation: AudioGeneration(rawValue: 1))
        let second = try await discovery.snapshot(generation: AudioGeneration(rawValue: 2))

        XCTAssertEqual(first.uid, second.uid)
        XCTAssertEqual(first.objectID, second.objectID)
        XCTAssertNotEqual(first.generation, second.generation)
        XCTAssertNotEqual(first, second)
    }
}

private final class DeviceOperationsStub: @unchecked Sendable, HALPropertyOperations {
    private let outputChannelCount: UInt32
    private let malformedStreamConfiguration: Bool

    init(
        outputChannelCount: UInt32 = 2,
        malformedStreamConfiguration: Bool = false
    ) {
        self.outputChannelCount = outputChannelCount
        self.malformedStreamConfiguration = malformedStreamConfiguration
    }

    func propertyDataSize(
        objectID: AudioObjectID,
        address: HALPropertyAddress
    ) -> (status: OSStatus, size: UInt32) {
        guard address.selector == kAudioDevicePropertyStreamConfiguration else {
            return (kAudio_ParamError, 0)
        }
        if malformedStreamConfiguration {
            return (noErr, UInt32(MemoryLayout<UInt32>.size))
        }
        return (noErr, UInt32(MemoryLayout<AudioBufferList>.size))
    }

    func propertyData(
        objectID: AudioObjectID,
        address: HALPropertyAddress,
        dataSize: inout UInt32,
        data: UnsafeMutableRawPointer
    ) -> OSStatus {
        switch address.selector {
        case kAudioHardwarePropertyDefaultOutputDevice:
            data.assumingMemoryBound(to: AudioObjectID.self).pointee = 42
            dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        case kAudioDevicePropertyDeviceUID:
            writeRetainedString("test-output-uid", dataSize: &dataSize, data: data)
        case kAudioObjectPropertyName:
            writeRetainedString("Test Output", dataSize: &dataSize, data: data)
        case kAudioDevicePropertyDeviceIsAlive:
            data.assumingMemoryBound(to: UInt32.self).pointee = 1
            dataSize = UInt32(MemoryLayout<UInt32>.size)
        case kAudioDevicePropertyNominalSampleRate:
            data.assumingMemoryBound(to: Double.self).pointee = 48_000
            dataSize = UInt32(MemoryLayout<Double>.size)
        case kAudioDevicePropertyStreamConfiguration:
            if malformedStreamConfiguration {
                data.assumingMemoryBound(to: UInt32.self).pointee = 2
                dataSize = UInt32(MemoryLayout<UInt32>.size)
            } else {
                let list = data.assumingMemoryBound(to: AudioBufferList.self)
                list.pointee.mNumberBuffers = 1
                list.pointee.mBuffers = AudioBuffer(
                    mNumberChannels: outputChannelCount,
                    mDataByteSize: 0,
                    mData: nil
                )
                dataSize = UInt32(MemoryLayout<AudioBufferList>.size)
            }
        case kAudioDevicePropertyBufferFrameSize:
            data.assumingMemoryBound(to: UInt32.self).pointee = 512
            dataSize = UInt32(MemoryLayout<UInt32>.size)
        case kAudioDevicePropertyBufferFrameSizeRange:
            data.assumingMemoryBound(to: AudioValueRange.self).pointee = AudioValueRange(
                mMinimum: 32,
                mMaximum: 4_096
            )
            dataSize = UInt32(MemoryLayout<AudioValueRange>.size)
        default:
            return kAudio_ParamError
        }
        return noErr
    }

    private func writeRetainedString(
        _ value: String,
        dataSize: inout UInt32,
        data: UnsafeMutableRawPointer
    ) {
        let retained = Unmanaged.passRetained(value as CFString)
        data.assumingMemoryBound(to: Optional<Unmanaged<CFString>>.self).pointee = retained
        dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    }
}
