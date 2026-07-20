import CoreAudio
import XCTest
@testable import EqualizerAU

final class AudioIOControllerTests: XCTestCase {
    func testCaptureFlattensPlanarInputAndOutputRestoresInterleavedLayout() throws {
        let bridge = try makeBridge(input: [1, 1], output: [2], maxFrames: 2, primeFrames: 2)
        defer { EAUAudioIOBridgeDestroy(bridge) }

        capture(bridge, buffers: [[1, 3], [2, 4]], channels: [1, 1])
        let output = render(bridge, channels: [2], frames: 2)
        let snapshot = EAUAudioIOBridgeGetSnapshot(bridge)

        XCTAssertEqual(output, [[1, 2, 3, 4]])
        XCTAssertEqual(snapshot.capturedFrames, 2)
        XCTAssertEqual(snapshot.renderedFrames, 2)
        XCTAssertEqual(snapshot.nonZeroSampleCount, 4)
        XCTAssertEqual(snapshot.renderedNonZeroSampleCount, 4)
    }

    func testPrimeOutputsWholeBlockSilenceThenSound() throws {
        let bridge = try makeBridge(maxFrames: 2, primeFrames: 4)
        defer { EAUAudioIOBridgeDestroy(bridge) }

        capture(bridge, buffers: [[1, 2, 3, 4]], channels: [2])
        XCTAssertEqual(render(bridge, channels: [2], frames: 2), [[0, 0, 0, 0]])
        capture(bridge, buffers: [[5, 6, 7, 8]], channels: [2])
        XCTAssertEqual(render(bridge, channels: [2], frames: 2), [[1, 2, 3, 4]])
        XCTAssertEqual(EAUAudioIOBridgeGetSnapshot(bridge).primingBlocks, 1)
    }

    func testRenderClearsIncomingSilenceFlagWhenItSubmitsNonzeroSamples() throws {
        let bridge = try makeBridge(maxFrames: 2, primeFrames: 2)
        defer { EAUAudioIOBridgeDestroy(bridge) }
        capture(bridge, buffers: [[1, -1, 0.5, -0.5]], channels: [2])
        var flags = AudioUnitRenderActionFlags.unitRenderAction_OutputIsSilence

        let output = render(bridge, flags: &flags, channels: [2], frames: 2)
        let snapshot = EAUAudioIOBridgeGetSnapshot(bridge)

        XCTAssertEqual(output, [[1, -1, 0.5, -0.5]])
        XCTAssertFalse(flags.contains(.unitRenderAction_OutputIsSilence))
        XCTAssertEqual(snapshot.renderActionSilenceInputBlocks, 1)
        XCTAssertEqual(snapshot.renderActionSilenceClearedBlocks, 1)
        XCTAssertEqual(snapshot.outputSilenceBlocks, 0)
        XCTAssertEqual(snapshot.outputNonSilenceBlocks, 1)
    }

    func testRenderSetsSilenceFlagForPrimingAndStoppingBlocks() throws {
        let bridge = try makeBridge(maxFrames: 2, primeFrames: 4)
        defer { EAUAudioIOBridgeDestroy(bridge) }
        capture(bridge, buffers: [[1, 1, 1, 1]], channels: [2])
        var flags = AudioUnitRenderActionFlags(rawValue: 0)

        XCTAssertEqual(render(bridge, flags: &flags, channels: [2], frames: 2), [[0, 0, 0, 0]])
        XCTAssertTrue(flags.contains(.unitRenderAction_OutputIsSilence))

        EAUAudioIOBridgeBeginStopping(bridge)
        flags = AudioUnitRenderActionFlags(rawValue: 0)
        XCTAssertEqual(render(bridge, flags: &flags, channels: [2], frames: 2), [[0, 0, 0, 0]])
        XCTAssertTrue(flags.contains(.unitRenderAction_OutputIsSilence))
        let snapshot = EAUAudioIOBridgeGetSnapshot(bridge)
        XCTAssertEqual(snapshot.outputSilenceBlocks, 2)
        XCTAssertEqual(snapshot.outputNonSilenceBlocks, 0)
    }

    func testUnderrunZerosWholeBlockAndCountsIt() throws {
        let bridge = try makeBridge(maxFrames: 2, primeFrames: 2)
        defer { EAUAudioIOBridgeDestroy(bridge) }

        capture(bridge, buffers: [[1, 2, 3, 4]], channels: [2])
        XCTAssertEqual(render(bridge, channels: [2], frames: 2), [[1, 2, 3, 4]])
        XCTAssertEqual(render(bridge, channels: [2], frames: 2), [[0, 0, 0, 0]])
        XCTAssertEqual(EAUAudioIOBridgeGetSnapshot(bridge).underrunBlocks, 1)
        capture(bridge, buffers: [[5, 6, 7, 8]], channels: [2])
        XCTAssertEqual(render(bridge, channels: [2], frames: 2), [[5, 6, 7, 8]])
    }

    func testOverflowDropsIncomingWholeFrames() throws {
        let bridge = try makeBridge(maxFrames: 2, capacity: 4, primeFrames: 2)
        defer { EAUAudioIOBridgeDestroy(bridge) }

        capture(bridge, buffers: [[1, 2, 3, 4]], channels: [2])
        capture(bridge, buffers: [[5, 6, 7, 8]], channels: [2])
        capture(bridge, buffers: [[9, 10, 11, 12]], channels: [2])
        let snapshot = EAUAudioIOBridgeGetSnapshot(bridge)

        XCTAssertEqual(snapshot.overflowFrames, 2)
        XCTAssertEqual(snapshot.droppedFrames, 2)
        XCTAssertEqual(snapshot.ringFillFrames, 4)
    }

    func testBacklogCorrectionDropsOldestCompleteFrames() throws {
        let bridge = try makeBridge(maxFrames: 2, capacity: 8, primeFrames: 2, target: 2)
        defer { EAUAudioIOBridgeDestroy(bridge) }

        for value in stride(from: Float(1), through: 7, by: 2) {
            capture(bridge, buffers: [[value, value, value + 1, value + 1]], channels: [2])
        }
        XCTAssertEqual(render(bridge, channels: [2], frames: 2), [[7, 7, 8, 8]])
        let snapshot = EAUAudioIOBridgeGetSnapshot(bridge)
        XCTAssertEqual(snapshot.backlogCorrections, 1)
        XCTAssertEqual(snapshot.droppedFrames, 6)
    }

    func testFadeIsMonotonicAndCompletes() throws {
        let bridge = try makeBridge(maxFrames: 4, primeFrames: 4)
        defer { EAUAudioIOBridgeDestroy(bridge) }
        capture(bridge, buffers: [[1, 1, 1, 1, 1, 1, 1, 1]], channels: [2])

        EAUAudioIOBridgeRequestFadeOut(bridge, 4)
        let values = render(bridge, channels: [2], frames: 4)[0]

        XCTAssertEqual(values, [1, 1, 0.75, 0.75, 0.5, 0.5, 0.25, 0.25])
        XCTAssertTrue(EAUAudioIOBridgeIsFadeComplete(bridge))

        capture(bridge, buffers: [[1, 1, 1, 1, 1, 1, 1, 1]], channels: [2])
        EAUAudioIOBridgeRequestFadeOut(bridge, 4)
        XCTAssertEqual(render(bridge, channels: [2], frames: 4), [[0, 0, 0, 0, 0, 0, 0, 0]])
    }

    func testValidationGainAttenuatesAndClampsUnsafeSamples() throws {
        let bridge = try makeBridge(
            maxFrames: 2,
            primeFrames: 2,
            outputGain: 0.05,
            outputLimit: 0.10
        )
        defer { EAUAudioIOBridgeDestroy(bridge) }

        capture(
            bridge,
            buffers: [[1, -1, 100, -100]],
            channels: [2]
        )

        XCTAssertEqual(
            render(bridge, channels: [2], frames: 2)[0],
            [0.05, -0.05, 0.10, -0.10]
        )
    }

    func testValidationOutputReplacesNonFiniteSamplesWithSilence() throws {
        let bridge = try makeBridge(
            maxFrames: 2,
            primeFrames: 2,
            outputGain: 0.05,
            outputLimit: 0.10
        )
        defer { EAUAudioIOBridgeDestroy(bridge) }

        capture(
            bridge,
            buffers: [[.nan, .infinity, -.infinity, 0.5]],
            channels: [2]
        )

        XCTAssertEqual(
            render(bridge, channels: [2], frames: 2)[0],
            [0, 0, 0, 0.025]
        )
    }

    func testMVPOutputUsesFixedMinus12dBGainAndMatchingSafetyLimit() throws {
        let expectedGain = Float(pow(10.0, -12.0 / 20.0))
        XCTAssertEqual(AudioIOController.mvpOutputGain, expectedGain, accuracy: 0.000_001)
        XCTAssertEqual(AudioIOController.mvpOutputLimit, expectedGain, accuracy: 0.000_001)

        let bridge = try makeBridge(
            maxFrames: 2,
            primeFrames: 2,
            outputGain: AudioIOController.mvpOutputGain,
            outputLimit: AudioIOController.mvpOutputLimit
        )
        defer { EAUAudioIOBridgeDestroy(bridge) }

        capture(bridge, buffers: [[1, -1, 2, -2]], channels: [2])
        let output = render(bridge, channels: [2], frames: 2)[0]

        XCTAssertEqual(output[0], expectedGain, accuracy: 0.000_001)
        XCTAssertEqual(output[1], -expectedGain, accuracy: 0.000_001)
        XCTAssertEqual(output[2], expectedGain, accuracy: 0.000_001)
        XCTAssertEqual(output[3], -expectedGain, accuracy: 0.000_001)
        XCTAssertEqual(EAUAudioIOBridgeGetSnapshot(bridge).renderedNonZeroSampleCount, 4)
    }

    func testSignalProbesMeasureCapturePostDSPAndActualAppleSubmission() throws {
        let bridge = try makeBridge(
            maxFrames: 4,
            primeFrames: 4,
            outputGain: 0.25,
            outputLimit: 1
        )
        defer { EAUAudioIOBridgeDestroy(bridge) }
        let input: [Float] = [1, -1, 0.5, -0.5, 0.25, -0.25, 0.125, -0.125]

        capture(bridge, buffers: [input], channels: [2])
        let rendered = render(bridge, channels: [2], frames: 4)[0]
        let captureProbe = try copyProbe(bridge, stage: EAUAudioSignalProbeCapture)
        let postDSPProbe = try copyProbe(bridge, stage: EAUAudioSignalProbePostDSP)
        let submitProbe = try copyProbe(bridge, stage: EAUAudioSignalProbeAppleSubmit)

        XCTAssertEqual(captureProbe.samples, input)
        XCTAssertEqual(postDSPProbe.samples, input.map { $0 * 0.25 })
        XCTAssertEqual(submitProbe.samples, postDSPProbe.samples)
        XCTAssertEqual(rendered, submitProbe.samples)
        for metadata in [captureProbe.metadata, postDSPProbe.metadata, submitProbe.metadata] {
            XCTAssertEqual(metadata.sequence, 1)
            XCTAssertEqual(metadata.frameCount, 4)
            XCTAssertEqual(metadata.channelCount, 2)
            XCTAssertEqual(metadata.droppedFrames, 0)
        }
    }

    func testSignalProbeDropsDiagnosticFramesWithoutAffectingAudioTransport() throws {
        let bridge = try makeBridge(maxFrames: 2, capacity: 8, primeFrames: 2)
        defer { EAUAudioIOBridgeDestroy(bridge) }

        capture(bridge, buffers: [[1, 1, 2, 2]], channels: [2])
        capture(bridge, buffers: [[3, 3, 4, 4]], channels: [2])
        capture(bridge, buffers: [[5, 5, 6, 6]], channels: [2])
        capture(bridge, buffers: [[7, 7, 8, 8]], channels: [2])

        let newest = try copyProbe(bridge, stage: EAUAudioSignalProbeCapture)
        XCTAssertEqual(newest.samples, [5, 5, 6, 6])
        XCTAssertEqual(newest.metadata.sequence, 3)
        XCTAssertEqual(newest.metadata.droppedFrames, 2)
        XCTAssertEqual(EAUAudioIOBridgeGetSnapshot(bridge).capturedFrames, 8)
    }

    func testProductionRenderUsesRequestedFramesInsteadOfBufferCapacity() throws {
        let bridge = try makeBridge(maxFrames: 4, primeFrames: 2, target: 4)
        defer { EAUAudioIOBridgeDestroy(bridge) }
        capture(bridge, buffers: [[1, 2, 3, 4, 5, 6, 7, 8]], channels: [2])

        let output = renderRequested(
            bridge, channels: [2], capacityFrames: 4, requestedFrames: 2
        )
        let snapshot = EAUAudioIOBridgeGetSnapshot(bridge)

        XCTAssertEqual(output, [[1, 2, 3, 4, 0, 0, 0, 0]])
        XCTAssertEqual(snapshot.renderedFrames, 2)
        XCTAssertEqual(snapshot.ringFillFrames, 2)
    }

    func testControllerStartsCaptureBeforeCreatingAndStartingOutput() async throws {
        let operations = AudioDeviceIOOperationsStub()
        let controller = AudioIOController(operations: operations, debugLogger: NullAudioDebugLogger())
        var resource = try await controller.create(
            aggregate: aggregateResource(), tap: tapResource(), output: outputSnapshot(), maxFrames: 64
        )

        resource = try await controller.startCapture(resource)
        resource = try await controller.createOutput(resource)
        resource = try await controller.startOutput(resource)
        resource = try await controller.stop(resource)
        try await controller.destroy(resource)

        XCTAssertEqual(
            operations.calls,
            ["create.capture:800", "start.capture", "create.output:600:48000:2:64", "start.output",
             "stop.output", "stop.capture", "destroy.output", "destroy.capture"]
        )
    }

    func testDestroyFailureRetainsRemainingRegistrationForRetry() async throws {
        let operations = AudioDeviceIOOperationsStub(destroyCaptureStatuses: [-50, noErr])
        let controller = AudioIOController(operations: operations, debugLogger: NullAudioDebugLogger())
        let resource = try await controller.create(
            aggregate: aggregateResource(), tap: tapResource(), output: outputSnapshot(), maxFrames: 64
        )

        await XCTAssertThrowsAudioIOErrorAsync(try await controller.destroy(resource))
        try await controller.destroy(resource)

        XCTAssertEqual(
            operations.calls,
            ["create.capture:800", "destroy.capture", "destroy.capture"]
        )
    }

    func testOutputStopFailureStillStopsCaptureAndRetryOnlyStopsOutput() async throws {
        let operations = AudioDeviceIOOperationsStub(stopOutputStatuses: [-50, noErr])
        let controller = AudioIOController(operations: operations, debugLogger: NullAudioDebugLogger())
        var resource = try await controller.create(
            aggregate: aggregateResource(), tap: tapResource(), output: outputSnapshot(), maxFrames: 64
        )
        resource = try await controller.startCapture(resource)
        resource = try await controller.createOutput(resource)
        resource = try await controller.startOutput(resource)

        await XCTAssertThrowsAudioIOErrorAsync(try await controller.stop(resource))
        resource = try await controller.stop(resource)
        try await controller.destroy(resource)

        XCTAssertEqual(
            operations.calls,
            ["create.capture:800", "start.capture", "create.output:600:48000:2:64", "start.output",
             "stop.output", "stop.capture", "stop.output", "destroy.output", "destroy.capture"]
        )
    }

    func testOutputCreationFailureLeavesStartedCaptureAvailableForCleanup() async throws {
        let operations = AudioDeviceIOOperationsStub(
            createOutputStatuses: [-50]
        )
        let controller = AudioIOController(operations: operations, debugLogger: NullAudioDebugLogger())

        var resource = try await controller.create(
            aggregate: aggregateResource(), tap: tapResource(),
            output: outputSnapshot(), maxFrames: 64
        )
        resource = try await controller.startCapture(resource)
        await XCTAssertThrowsAudioIOErrorAsync(
            try await controller.createOutput(resource)
        )
        resource = try await controller.stop(resource)
        try await controller.destroy(resource)

        XCTAssertEqual(
            operations.calls,
            ["create.capture:800", "start.capture", "create.output:600:48000:2:64",
             "stop.capture", "destroy.capture"]
        )
    }

    func testOutputDiagnosticsMismatchRetainsOutputForCleanup() async throws {
        let operations = AudioDeviceIOOperationsStub(diagnosticsCurrentDevice: 999)
        let controller = AudioIOController(operations: operations, debugLogger: NullAudioDebugLogger())

        var resource = try await controller.create(
            aggregate: aggregateResource(), tap: tapResource(),
            output: outputSnapshot(), maxFrames: 64
        )
        resource = try await controller.startCapture(resource)
        await XCTAssertThrowsAudioIOErrorAsync(try await controller.createOutput(resource))
        resource = try await controller.stop(resource)
        try await controller.destroy(resource)

        XCTAssertEqual(
            operations.calls,
            ["create.capture:800", "start.capture", "create.output:600:48000:2:64",
             "stop.capture", "destroy.output", "destroy.capture"]
        )
    }

    func testOutputCannotBeCreatedBeforeCaptureStarts() async throws {
        let operations = AudioDeviceIOOperationsStub()
        let controller = AudioIOController(operations: operations, debugLogger: NullAudioDebugLogger())
        let resource = try await controller.create(
            aggregate: aggregateResource(), tap: tapResource(), output: outputSnapshot(), maxFrames: 64
        )

        await XCTAssertThrowsAudioIOErrorAsync(try await controller.createOutput(resource))
        try await controller.destroy(resource)

        XCTAssertEqual(operations.calls, ["create.capture:800", "destroy.capture"])
    }

    func testPreflightRejectsSampleRateAndLayoutMismatchBeforeRegistration() async {
        let operations = AudioDeviceIOOperationsStub()
        let controller = AudioIOController(operations: operations, debugLogger: NullAudioDebugLogger())

        await XCTAssertThrowsAudioIOErrorAsync(
            try await controller.create(
                aggregate: aggregateResource(sampleRate: 44_100), tap: tapResource(sampleRate: 44_100),
                output: outputSnapshot(), maxFrames: 64
            )
        )
        await XCTAssertThrowsAudioIOErrorAsync(
            try await controller.create(
                aggregate: aggregateResource(inputChannels: [1]), tap: tapResource(),
                output: outputSnapshot(), maxFrames: 64
            )
        )
        XCTAssertTrue(operations.calls.isEmpty)
    }

    func testDestroyedResourceFailsClosedAsStale() async throws {
        let operations = AudioDeviceIOOperationsStub()
        let controller = AudioIOController(operations: operations, debugLogger: NullAudioDebugLogger())
        let resource = try await controller.create(
            aggregate: aggregateResource(), tap: tapResource(), output: outputSnapshot(), maxFrames: 64
        )

        try await controller.destroy(resource)

        await XCTAssertThrowsSpecificAudioIOErrorAsync(
            try await controller.startCapture(resource),
            expected: .staleResource
        )
        await XCTAssertThrowsSpecificAudioIOErrorAsync(
            try await controller.destroy(resource),
            expected: .staleResource
        )
        await XCTAssertThrowsSpecificAudioIOErrorAsync(
            try await controller.snapshot(resource),
            expected: .staleResource
        )
        await XCTAssertThrowsSpecificAudioIOErrorAsync(
            try await controller.signalProbes(resource),
            expected: .staleResource
        )
    }

    func testConcurrentDestroyIsRejectedWhileStopIsSuspended() async throws {
        let operations = AudioDeviceIOOperationsStub()
        let controller = AudioIOController(operations: operations, debugLogger: NullAudioDebugLogger())
        var resource = try await controller.create(
            aggregate: aggregateResource(), tap: tapResource(), output: outputSnapshot(), maxFrames: 64
        )
        resource = try await controller.startCapture(resource)
        resource = try await controller.createOutput(resource)
        resource = try await controller.startOutput(resource)

        let startedResource = resource
        let stopTask = Task { try await controller.stop(startedResource) }
        while EAUAudioIOBridgeIsFadeComplete(startedResource.bridge) {
            await Task.yield()
        }
        await XCTAssertThrowsSpecificAudioIOErrorAsync(
            try await controller.destroy(startedResource),
            expected: .operationInProgress("stopping")
        )
        let stoppedResource = try await stopTask.value
        try await controller.destroy(stoppedResource)
    }
}

private final class AudioDeviceIOOperationsStub: AudioDeviceIOOperations, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [String] = []
    private var destroyCaptureStatuses: [OSStatus]
    private var destroyOutputStatuses: [OSStatus]
    private var stopOutputStatuses: [OSStatus]
    private var createCaptureStatuses: [OSStatus]
    private var createOutputStatuses: [OSStatus]
    private let diagnosticsCurrentDevice: AudioObjectID
    private var outputRunning = false
    private let outputRegistration = OpaquePointer(bitPattern: 0x1000)!
    private let captureRegistration = OpaquePointer(bitPattern: 0x2000)!

    init(
        destroyCaptureStatuses: [OSStatus] = [noErr],
        destroyOutputStatuses: [OSStatus] = [noErr],
        stopOutputStatuses: [OSStatus] = [noErr],
        createCaptureStatuses: [OSStatus] = [noErr],
        createOutputStatuses: [OSStatus] = [noErr],
        diagnosticsCurrentDevice: AudioObjectID = 600
    ) {
        self.destroyCaptureStatuses = destroyCaptureStatuses
        self.destroyOutputStatuses = destroyOutputStatuses
        self.stopOutputStatuses = stopOutputStatuses
        self.createCaptureStatuses = createCaptureStatuses
        self.createOutputStatuses = createOutputStatuses
        self.diagnosticsCurrentDevice = diagnosticsCurrentDevice
    }

    var calls: [String] { lock.withLock { recordedCalls } }

    func createCaptureIOProc(
        deviceID: AudioObjectID,
        bridge: OpaquePointer,
        registration: inout OpaquePointer?
    ) -> OSStatus {
        lock.withLock { recordedCalls.append("create.capture:\(deviceID)") }
        let status = lock.withLock {
            createCaptureStatuses.isEmpty ? noErr : createCaptureStatuses.removeFirst()
        }
        guard status == noErr else { return status }
        registration = captureRegistration
        return noErr
    }

    func createOutputUnit(
        deviceID: AudioObjectID,
        bridge: OpaquePointer,
        sampleRate: Double,
        channelCount: UInt32,
        maximumFrames: UInt32,
        outputUnit: inout OpaquePointer?
    ) -> OSStatus {
        lock.withLock {
            recordedCalls.append("create.output:\(deviceID):\(Int(sampleRate)):\(channelCount):\(maximumFrames)")
        }
        let status = lock.withLock {
            createOutputStatuses.isEmpty ? noErr : createOutputStatuses.removeFirst()
        }
        guard status == noErr else { return status }
        outputUnit = outputRegistration
        return noErr
    }

    func startCapture(registration: OpaquePointer) -> OSStatus {
        lock.withLock { recordedCalls.append("start.capture") }
        return noErr
    }

    func stopCapture(registration: OpaquePointer) -> OSStatus {
        lock.withLock { recordedCalls.append("stop.capture") }
        return noErr
    }

    func destroyCapture(registration: OpaquePointer) -> OSStatus {
        lock.withLock {
            recordedCalls.append("destroy.capture")
            return destroyCaptureStatuses.isEmpty ? noErr : destroyCaptureStatuses.removeFirst()
        }
    }

    func startOutput(outputUnit: OpaquePointer) -> OSStatus {
        lock.withLock {
            recordedCalls.append("start.output")
            outputRunning = true
        }
        return noErr
    }

    func stopOutput(outputUnit: OpaquePointer) -> OSStatus {
        lock.withLock {
            recordedCalls.append("stop.output")
            let status = stopOutputStatuses.isEmpty ? noErr : stopOutputStatuses.removeFirst()
            if status == noErr { outputRunning = false }
            return status
        }
    }

    func destroyOutput(outputUnit: OpaquePointer) -> OSStatus {
        lock.withLock {
            recordedCalls.append("destroy.output")
            return destroyOutputStatuses.isEmpty ? noErr : destroyOutputStatuses.removeFirst()
        }
    }

    func outputDiagnostics(outputUnit: OpaquePointer) -> Result<AudioOutputUnitDiagnostics, AudioIOError> {
        let running = lock.withLock { outputRunning }
        let format = AudioStreamBasicDescription(
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
        return .success(AudioOutputUnitDiagnostics(
            componentSubType: kAudioUnitSubType_DefaultOutput,
            currentDevice: diagnosticsCurrentDevice,
            deviceFormat: format,
            clientFormat: format,
            maximumFrames: 64,
            isRunning: running,
            volume: 1,
            isRunningStatus: noErr,
            volumeStatus: noErr
        ))
    }
}

private func makeBridge(
    input: [UInt32] = [2],
    output: [UInt32] = [2],
    maxFrames: UInt32,
    capacity: UInt32 = 16,
    primeFrames: UInt32,
    target: UInt32? = nil,
    outputGain: Float = 1.0,
    outputLimit: Float = 1_000.0
) throws -> OpaquePointer {
    let bridge = input.withUnsafeBufferPointer { inputPointer in
        output.withUnsafeBufferPointer { outputPointer in
            EAUAudioIOBridgeCreate(
                inputPointer.baseAddress, UInt32(input.count),
                outputPointer.baseAddress, UInt32(output.count),
                4, maxFrames, capacity, primeFrames, target ?? primeFrames,
                outputGain, outputLimit
            )
        }
    }
    return try XCTUnwrap(bridge)
}

private func copyProbe(
    _ bridge: OpaquePointer,
    stage: EAUAudioSignalProbeStage
) throws -> (samples: [Float], metadata: EAUAudioSignalProbeMetadata) {
    let frames = EAUAudioIOBridgeGetSignalProbeFrameCapacity(bridge)
    let channels = EAUAudioIOBridgeGetSignalProbeChannelCount(bridge)
    var samples = [Float](repeating: 0, count: Int(frames * channels))
    var metadata = EAUAudioSignalProbeMetadata()
    let copied = samples.withUnsafeMutableBufferPointer { buffer in
        EAUAudioIOBridgeCopyLatestSignalProbe(
            bridge, stage, buffer.baseAddress, UInt32(buffer.count), &metadata
        )
    }
    XCTAssertGreaterThan(copied, 0)
    samples.removeSubrange(Int(copied)..<samples.count)
    return (samples, metadata)
}

private func capture(_ bridge: OpaquePointer, buffers: [[Float]], channels: [UInt32]) {
    _ = withAllocatedABL(buffers: buffers, channels: channels) { list in
        _ = EAUAudioIOBridgeCapture(bridge, nil, UnsafePointer(list))
    }
}

private func render(_ bridge: OpaquePointer, channels: [UInt32], frames: Int) -> [[Float]] {
    withAllocatedABL(
        buffers: channels.map { [Float](repeating: 9, count: frames * Int($0)) },
        channels: channels
    ) { list in
        _ = EAUAudioIOBridgeRender(bridge, nil, list)
    }
}

private func render(
    _ bridge: OpaquePointer,
    flags: inout AudioUnitRenderActionFlags,
    channels: [UInt32],
    frames: Int
) -> [[Float]] {
    withAllocatedABL(
        buffers: channels.map { [Float](repeating: 9, count: frames * Int($0)) },
        channels: channels
    ) { list in
        _ = EAUAudioIOBridgeRenderWithActionFlags(bridge, &flags, nil, list)
    }
}

private func renderRequested(
    _ bridge: OpaquePointer,
    channels: [UInt32],
    capacityFrames: Int,
    requestedFrames: UInt32
) -> [[Float]] {
    withAllocatedABL(
        buffers: channels.map { [Float](repeating: 9, count: capacityFrames * Int($0)) },
        channels: channels
    ) { list in
        _ = EAUAudioIOBridgeRenderFramesWithActionFlags(
            bridge, nil, nil, requestedFrames, list
        )
    }
}

private func withAllocatedABL(
    buffers: [[Float]],
    channels: [UInt32],
    body: (UnsafeMutablePointer<AudioBufferList>) -> Void
) -> [[Float]] {
    precondition(buffers.count == channels.count)
    let samplePointers = buffers.map { values -> UnsafeMutablePointer<Float> in
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: values.count)
        pointer.initialize(from: values, count: values.count)
        return pointer
    }
    let offset = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers)!
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: offset + buffers.count * MemoryLayout<AudioBuffer>.stride,
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    list.pointee.mNumberBuffers = UInt32(buffers.count)
    let first = raw.advanced(by: offset).bindMemory(to: AudioBuffer.self, capacity: buffers.count)
    for index in buffers.indices {
        first[index] = AudioBuffer(
            mNumberChannels: channels[index],
            mDataByteSize: UInt32(buffers[index].count * MemoryLayout<Float>.size),
            mData: samplePointers[index]
        )
    }
    _ = body(list)
    let result = buffers.indices.map { index in
        Array(UnsafeBufferPointer<Float>(start: samplePointers[index], count: buffers[index].count))
    }
    for (index, pointer) in samplePointers.enumerated() {
        pointer.deinitialize(count: buffers[index].count)
        pointer.deallocate()
    }
    raw.deallocate()
    return result
}

private func XCTAssertThrowsAudioIOErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}

private func XCTAssertThrowsSpecificAudioIOErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    expected: AudioIOError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as AudioIOError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}

private func aggregateResource(
    inputChannels: [UInt32] = [2],
    sampleRate: Double = 48_000
) -> AggregateDeviceResource {
    AggregateDeviceResource(
        descriptor: AudioResourceDescriptor(
            generation: AudioGeneration(rawValue: 1), kind: .aggregateDevice,
            objectID: 800, persistentUID: "test.aggregate"
        ),
        outputDeviceUID: "test.output",
        tapUID: "test.tap",
        tapUIDs: ["test.tap"],
        inputLayout: AudioBufferLayout(
            buffers: inputChannels.enumerated().map { .init(index: $0.offset, channelCount: $0.element) }
        ),
        inputFormat: AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked, mBytesPerPacket: 8,
            mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0
        ),
        nominalSampleRate: sampleRate,
        maximumFrames: 512
    )
}

private func outputSnapshot() -> AudioDeviceSnapshot {
    AudioDeviceSnapshot(
        generation: AudioGeneration(rawValue: 1), objectID: 600, uid: "test.output",
        name: "Test Output", isAlive: true, nominalSampleRate: 48_000,
        outputChannelCount: 2,
        outputLayout: AudioBufferLayout(buffers: [.init(index: 0, channelCount: 2)]),
        bufferFrameSize: 64, bufferFrameSizeRange: 32...512
    )
}

private func tapResource(sampleRate: Double = 48_000) -> ProcessTapResource {
    ProcessTapResource(
        descriptor: AudioResourceDescriptor(
            generation: AudioGeneration(rawValue: 1), kind: .processTap,
            objectID: 700, persistentUID: "test.tap"
        ),
        selfProcessObjectID: 600,
        format: AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat, mBytesPerPacket: 8,
            mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0
        ),
        muteBehavior: .muted
    )
}
