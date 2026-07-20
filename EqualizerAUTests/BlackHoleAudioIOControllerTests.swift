import AudioToolbox
import CoreAudio
import XCTest
@testable import EqualizerAU

final class BlackHoleAudioIOControllerTests: XCTestCase {
    func testCreateUsesExplicitHALOutputAndSeparateBlackHoleCapture() async throws {
        let operations = BlackHoleAudioIOOperationsStub()
        let controller = BlackHoleAudioIOController(
            operations: operations,
            debugLogger: NullAudioDebugLogger()
        )

        let resource = try await controller.create(
            blackHole: blackHoleIOFixture(),
            physicalOutput: physicalOutputFixture(),
            maximumFrames: 512
        )
        try await controller.destroy(resource)

        XCTAssertEqual(operations.calls, [
            "create.hal-output:600:48000:2:512",
            "diagnostics.output",
            "create.capture:700",
            "destroy.output",
            "destroy.capture"
        ])
    }

    func testLifecycleMethodsPreserveCaptureFirstStartAndOutputFirstStopControl() async throws {
        let operations = BlackHoleAudioIOOperationsStub()
        let controller = BlackHoleAudioIOController(
            operations: operations,
            debugLogger: NullAudioDebugLogger()
        )
        var resource = try await controller.create(
            blackHole: blackHoleIOFixture(),
            physicalOutput: physicalOutputFixture(),
            maximumFrames: 512
        )

        resource = try await controller.startCapture(resource)
        resource = try await controller.startOutput(resource)
        resource = try await controller.stopOutput(resource)
        resource = try await controller.stopCapture(resource)
        try await controller.destroy(resource)

        XCTAssertEqual(Array(operations.calls.suffix(6)), [
            "start.capture", "start.output", "stop.output", "stop.capture",
            "destroy.output", "destroy.capture"
        ])
    }

    func testReadbackMismatchDestroysOutputWithoutCreatingCapture() async {
        let operations = BlackHoleAudioIOOperationsStub(componentSubType: kAudioUnitSubType_DefaultOutput)
        let controller = BlackHoleAudioIOController(
            operations: operations,
            debugLogger: NullAudioDebugLogger()
        )

        await XCTAssertThrowsBlackHoleAudioIOErrorAsync(
            try await controller.create(
                blackHole: blackHoleIOFixture(),
                physicalOutput: physicalOutputFixture(),
                maximumFrames: 512
            )
        )

        XCTAssertEqual(operations.calls, [
            "create.hal-output:600:48000:2:512",
            "diagnostics.output",
            "destroy.output"
        ])
    }

    func testPreflightRejectsSampleRateMismatchBeforeCreatingResources() async {
        let operations = BlackHoleAudioIOOperationsStub()
        let controller = BlackHoleAudioIOController(
            operations: operations,
            debugLogger: NullAudioDebugLogger()
        )

        await XCTAssertThrowsBlackHoleAudioIOErrorAsync(
            try await controller.create(
                blackHole: blackHoleIOFixture(sampleRate: 44_100),
                physicalOutput: physicalOutputFixture(),
                maximumFrames: 512
            )
        )
        XCTAssertTrue(operations.calls.isEmpty)
    }

    func testCaptureCreationCleanupFailureRetainsOutputUntilNextCreateRetries() async throws {
        let operations = BlackHoleAudioIOOperationsStub(
            createCaptureStatuses: [-50, noErr],
            destroyOutputStatuses: [-51, noErr, noErr]
        )
        let controller = BlackHoleAudioIOController(
            operations: operations,
            debugLogger: NullAudioDebugLogger()
        )

        await XCTAssertThrowsBlackHoleAudioIOErrorAsync(
            try await controller.create(
                blackHole: blackHoleIOFixture(),
                physicalOutput: physicalOutputFixture(),
                maximumFrames: 512
            )
        )
        let resource = try await controller.create(
            blackHole: blackHoleIOFixture(),
            physicalOutput: physicalOutputFixture(),
            maximumFrames: 512
        )
        try await controller.destroy(resource)

        XCTAssertEqual(operations.calls.filter { $0 == "destroy.output" }.count, 3)
        XCTAssertEqual(operations.calls.filter { $0 == "create.capture:700" }.count, 2)
    }

    func testResetClearsPreflightTransportStateAndCancelFadeRearamsOutput() async throws {
        let operations = BlackHoleAudioIOOperationsStub()
        let controller = BlackHoleAudioIOController(
            operations: operations,
            debugLogger: NullAudioDebugLogger()
        )
        let resource = try await controller.create(
            blackHole: blackHoleIOFixture(),
            physicalOutput: physicalOutputFixture(),
            maximumFrames: 512
        )
        var samples = [Float](repeating: 0.25, count: 256)
        var timestamp = AudioTimeStamp()
        timestamp.mHostTime = 123
        timestamp.mFlags = .hostTimeValid
        let status = samples.withUnsafeMutableBytes { bytes -> OSStatus in
            var buffers = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(bytes.count),
                    mData: bytes.baseAddress
                )
            )
            return EAUAudioIOBridgeCapture(resource.bridge, &timestamp, &buffers)
        }
        XCTAssertEqual(status, noErr)
        let captured = await controller.snapshot(resource)
        XCTAssertGreaterThan(captured.capturedFrames, 0)

        try await controller.reset(resource)
        let reset = await controller.snapshot(resource)
        XCTAssertEqual(reset.capturedFrames, 0)
        XCTAssertEqual(reset.captureCallbackCount, 0)
        XCTAssertEqual(reset.ringFillFrames, 0)

        EAUAudioIOBridgeRequestFadeOut(resource.bridge, 512)
        XCTAssertFalse(EAUAudioIOBridgeIsFadeComplete(resource.bridge))
        await controller.cancelFadeOut(resource)
        XCTAssertTrue(EAUAudioIOBridgeIsFadeComplete(resource.bridge))
        try await controller.destroy(resource)
    }
}

private final class BlackHoleAudioIOOperationsStub: BlackHoleAudioIOOperations, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [String] = []
    private var createCaptureStatuses: [OSStatus]
    private var destroyOutputStatuses: [OSStatus]
    private let componentSubType: OSType
    private let capture = OpaquePointer(bitPattern: 0x7100)!
    private let output = OpaquePointer(bitPattern: 0x6100)!

    init(
        componentSubType: OSType = kAudioUnitSubType_HALOutput,
        createCaptureStatuses: [OSStatus] = [noErr],
        destroyOutputStatuses: [OSStatus] = [noErr]
    ) {
        self.componentSubType = componentSubType
        self.createCaptureStatuses = createCaptureStatuses
        self.destroyOutputStatuses = destroyOutputStatuses
    }

    var calls: [String] { lock.withLock { recordedCalls } }

    func createCapture(
        deviceID: AudioObjectID,
        bridge: OpaquePointer,
        registration: inout OpaquePointer?
    ) -> OSStatus {
        lock.withLock { recordedCalls.append("create.capture:\(deviceID)") }
        let status = lock.withLock {
            createCaptureStatuses.isEmpty ? noErr : createCaptureStatuses.removeFirst()
        }
        if status == noErr { registration = capture }
        return status
    }

    func createPhysicalOutput(
        deviceID: AudioObjectID,
        bridge: OpaquePointer,
        sampleRate: Double,
        channelCount: UInt32,
        maximumFrames: UInt32,
        outputUnit: inout OpaquePointer?
    ) -> OSStatus {
        lock.withLock {
            recordedCalls.append(
                "create.hal-output:\(deviceID):\(Int(sampleRate)):\(channelCount):\(maximumFrames)"
            )
        }
        outputUnit = output
        return noErr
    }

    func startCapture(_ registration: OpaquePointer) -> OSStatus {
        lock.withLock { recordedCalls.append("start.capture") }
        return noErr
    }

    func stopCapture(_ registration: OpaquePointer) -> OSStatus {
        lock.withLock { recordedCalls.append("stop.capture") }
        return noErr
    }

    func destroyCapture(_ registration: OpaquePointer) -> OSStatus {
        lock.withLock { recordedCalls.append("destroy.capture") }
        return noErr
    }

    func startOutput(_ outputUnit: OpaquePointer) -> OSStatus {
        lock.withLock { recordedCalls.append("start.output") }
        return noErr
    }

    func stopOutput(_ outputUnit: OpaquePointer) -> OSStatus {
        lock.withLock { recordedCalls.append("stop.output") }
        return noErr
    }

    func destroyOutput(_ outputUnit: OpaquePointer) -> OSStatus {
        lock.withLock {
            recordedCalls.append("destroy.output")
            return destroyOutputStatuses.isEmpty ? noErr : destroyOutputStatuses.removeFirst()
        }
    }

    func outputDiagnostics(
        _ outputUnit: OpaquePointer
    ) -> Result<AudioOutputUnitDiagnostics, BlackHoleAudioIOError> {
        lock.withLock { recordedCalls.append("diagnostics.output") }
        return .success(AudioOutputUnitDiagnostics(
            componentSubType: componentSubType,
            currentDevice: 600,
            deviceFormat: blackHoleIOFormat(),
            clientFormat: blackHoleIOFormat(),
            maximumFrames: 512,
            isRunning: false,
            volume: 1,
            isRunningStatus: noErr,
            volumeStatus: noErr
        ))
    }
}

private func blackHoleIOFixture(sampleRate: Double = 48_000) -> BlackHoleDeviceSnapshot {
    let layout = AudioBufferLayout(buffers: [.init(index: 0, channelCount: 2)])
    return BlackHoleDeviceSnapshot(
        generation: AudioGeneration(rawValue: 20),
        objectID: 700,
        uid: BlackHoleDeviceSnapshot.expectedUID,
        modelUID: BlackHoleDeviceSnapshot.expectedModelUID,
        name: BlackHoleDeviceSnapshot.expectedName,
        manufacturer: BlackHoleDeviceSnapshot.expectedManufacturer,
        transportType: kAudioDeviceTransportTypeVirtual,
        isAlive: true,
        isHidden: false,
        nominalSampleRate: sampleRate,
        clockDomain: 0,
        inputLayout: layout,
        outputLayout: layout,
        inputFormat: blackHoleIOFormat(sampleRate: sampleRate),
        outputFormat: blackHoleIOFormat(sampleRate: sampleRate)
    )
}

private func physicalOutputFixture() -> AudioDeviceSnapshot {
    AudioDeviceSnapshot(
        generation: AudioGeneration(rawValue: 20),
        objectID: 600,
        uid: "physical-output",
        name: "Physical Output",
        isAlive: true,
        nominalSampleRate: 48_000,
        outputChannelCount: 2,
        outputLayout: AudioBufferLayout(buffers: [.init(index: 0, channelCount: 2)]),
        bufferFrameSize: 128,
        bufferFrameSizeRange: 32...512
    )
}

private func blackHoleIOFormat(sampleRate: Double = 48_000) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: sampleRate,
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

private func XCTAssertThrowsBlackHoleAudioIOErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected BlackHole audio IO error", file: file, line: line)
    } catch {}
}
