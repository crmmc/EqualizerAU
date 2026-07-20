import CoreAudio
import XCTest
@testable import EqualizerAU

final class BlackHoleAudioPipelineTests: XCTestCase {
    func testStartCreatesInertIOThenRoutesAndStartsCaptureBeforeOutput() async throws {
        let events = PipelineEventRecorder()
        let io = PipelineIOStub(events: events)
        let pipeline = makePipeline(events: events, io: io)

        let result = try await pipeline.start(generation: pipelineGeneration)

        XCTAssertTrue(result.routeActive)
        XCTAssertEqual(result.physicalOutputName, "Physical Output (48000 Hz, 2 ch)")
        XCTAssertEqual(events.values, [
            "route.recover",
            "output.snapshot",
            "blackhole.snapshot",
            "io.create",
            "io.start.output",
            "io.snapshot.output-ready",
            "io.stop.output",
            "io.start.capture",
            "io.snapshot.capture-preflight-ready",
            "io.stop.capture",
            "io.reset",
            "route.activate",
            "io.start.capture",
            "io.snapshot.capture-ready",
            "io.start.output",
            "io.snapshot.output-ready",
            "io.snapshot.output-ready"
        ])
    }

    func testStopFadesBeforeRouteRestoreAndEndpointTeardown() async throws {
        let events = PipelineEventRecorder()
        let io = PipelineIOStub(events: events)
        let pipeline = makePipeline(events: events, io: io)
        _ = try await pipeline.start(generation: pipelineGeneration)
        events.clear()

        try await pipeline.stop()

        XCTAssertEqual(events.values, [
            "io.fade",
            "route.restore",
            "io.stop.output",
            "io.stop.capture",
            "io.destroy"
        ])
        let hasPending = await pipeline.hasPendingResources()
        XCTAssertFalse(hasPending)
    }

    func testRoutedOutputStartFailureRestoresRouteThenStopsCaptureAndDestroysIO() async {
        let events = PipelineEventRecorder()
        let io = PipelineIOStub(events: events, outputStartStatuses: [true, false])
        let pipeline = makePipeline(events: events, io: io)

        await XCTAssertThrowsBlackHolePipelineErrorAsync(
            try await pipeline.start(generation: pipelineGeneration)
        )

        XCTAssertEqual(Array(events.values.suffix(4)), [
            "io.start.output", "route.restore", "io.stop.capture", "io.destroy"
        ])
        let hasPending = await pipeline.hasPendingResources()
        XCTAssertFalse(hasPending)
    }

    func testRouteRestoreFailureRetainsRunningChainAndRetriesBeforeTeardown() async throws {
        let events = PipelineEventRecorder()
        let route = PipelineRouteStub(events: events, restoreStatuses: [false, true])
        let io = PipelineIOStub(events: events)
        let pipeline = makePipeline(events: events, route: route, io: io)
        _ = try await pipeline.start(generation: pipelineGeneration)
        events.clear()

        await XCTAssertThrowsBlackHolePipelineErrorAsync(try await pipeline.stop())
        XCTAssertEqual(events.values, ["io.fade", "route.restore", "io.cancel-fade"])
        let pendingAfterFailure = await pipeline.hasPendingResources()
        XCTAssertTrue(pendingAfterFailure)

        events.clear()
        try await pipeline.stop()
        XCTAssertEqual(events.values, [
            "io.fade", "route.restore", "io.stop.output", "io.stop.capture", "io.destroy"
        ])
        let pendingAfterRetry = await pipeline.hasPendingResources()
        XCTAssertFalse(pendingAfterRetry)
    }

    func testFadeFailureStillRestoresRouteAndTearsDownEndpoints() async throws {
        let events = PipelineEventRecorder()
        let io = PipelineIOStub(events: events, fadeStatuses: [false])
        let pipeline = makePipeline(events: events, io: io)
        _ = try await pipeline.start(generation: pipelineGeneration)
        events.clear()

        await XCTAssertThrowsBlackHolePipelineErrorAsync(try await pipeline.stop())

        XCTAssertEqual(events.values, [
            "io.fade", "route.restore", "io.stop.output", "io.stop.capture", "io.destroy"
        ])
        let hasPending = await pipeline.hasPendingResources()
        XCTAssertFalse(hasPending)
    }

    func testCaptureReadinessTimeoutRestoresRouteAndCleansIO() async {
        let events = PipelineEventRecorder()
        let io = PipelineIOStub(events: events, readiness: .neverRoutedCapture)
        let pipeline = makePipeline(events: events, io: io, readinessAttempts: 2)

        await XCTAssertThrowsBlackHolePipelineErrorAsync(
            try await pipeline.start(generation: pipelineGeneration)
        )

        XCTAssertTrue(events.values.contains("route.restore"))
        XCTAssertTrue(events.values.contains("io.stop.capture"))
        XCTAssertTrue(events.values.contains("io.destroy"))
        XCTAssertEqual(events.values.filter { $0 == "io.start.output" }.count, 1)
    }

    func testCapturePreflightTimeoutDoesNotActivateRoute() async {
        let events = PipelineEventRecorder()
        let io = PipelineIOStub(events: events, readiness: .neverPreflightCapture)
        let pipeline = makePipeline(events: events, io: io, readinessAttempts: 2)

        await XCTAssertThrowsBlackHolePipelineErrorAsync(
            try await pipeline.start(generation: pipelineGeneration)
        )

        XCTAssertFalse(events.values.contains("route.activate"))
        XCTAssertEqual(Array(events.values.suffix(2)), ["io.stop.capture", "io.destroy"])
    }

    func testStartupFailureBeforeRouteActivationDestroysInertIOWithoutRouteRestore() async {
        let events = PipelineEventRecorder()
        let route = PipelineRouteStub(events: events, activateSucceeds: false)
        let io = PipelineIOStub(events: events)
        let pipeline = makePipeline(events: events, route: route, io: io)

        await XCTAssertThrowsBlackHolePipelineErrorAsync(
            try await pipeline.start(generation: pipelineGeneration)
        )

        XCTAssertEqual(Array(events.values.suffix(2)), ["route.activate", "io.destroy"])
        XCTAssertFalse(events.values.contains("route.restore"))
    }

    private func makePipeline(
        events: PipelineEventRecorder,
        route: PipelineRouteStub? = nil,
        io: PipelineIOStub,
        readinessAttempts: Int = 3
    ) -> BlackHoleAudioPipeline {
        BlackHoleAudioPipeline(
            outputDiscovery: PipelineOutputStub(events: events),
            blackHoleDiscovery: PipelineBlackHoleStub(events: events),
            routeController: route ?? PipelineRouteStub(events: events),
            ioController: io,
            debugLogger: NullAudioDebugLogger(),
            readinessAttempts: readinessAttempts,
            readinessDelay: { _ in events.append("pipeline.delay") }
        )
    }
}

private let pipelineGeneration = AudioGeneration(rawValue: 90)

private final class PipelineEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
    func clear() { lock.withLock { storage.removeAll() } }
}

private struct PipelineOutputStub: DefaultOutputDeviceDiscovering {
    let events: PipelineEventRecorder
    func snapshot(generation: AudioGeneration) -> AudioDeviceSnapshot {
        events.append("output.snapshot")
        return pipelinePhysicalOutput(generation: generation)
    }
}

private struct PipelineBlackHoleStub: BlackHoleDeviceDiscovering {
    let events: PipelineEventRecorder
    func snapshot(generation: AudioGeneration) -> BlackHoleDeviceSnapshot {
        events.append("blackhole.snapshot")
        return pipelineBlackHole(generation: generation)
    }
}

private final class PipelineRouteStub: @unchecked Sendable, DefaultAudioRouteControlling {
    private let events: PipelineEventRecorder
    private let lock = NSLock()
    private let activateSucceeds: Bool
    private var restoreStatuses: [Bool]

    init(
        events: PipelineEventRecorder,
        activateSucceeds: Bool = true,
        restoreStatuses: [Bool] = [true]
    ) {
        self.events = events
        self.activateSucceeds = activateSucceeds
        self.restoreStatuses = restoreStatuses
    }

    func recoverIfNeeded() {
        events.append("route.recover")
    }

    func activate(
        virtualDevice: BlackHoleDeviceSnapshot,
        generation: AudioGeneration
    ) throws -> DefaultAudioRouteResource {
        events.append("route.activate")
        guard activateSucceeds else { throw PipelineTestError.injected("route activate") }
        return pipelineRouteResource(generation: generation)
    }

    func restore(_ resource: DefaultAudioRouteResource) throws {
        events.append("route.restore")
        let succeeds = lock.withLock {
            restoreStatuses.isEmpty ? true : restoreStatuses.removeFirst()
        }
        guard succeeds else { throw PipelineTestError.injected("route restore") }
    }
}

private final class PipelineIOStub: @unchecked Sendable, BlackHoleAudioIOControlling {
    enum Readiness: Equatable { case normal, neverPreflightCapture, neverRoutedCapture }

    private let events: PipelineEventRecorder
    private let readiness: Readiness
    private var outputStartStatuses: [Bool]
    private var fadeStatuses: [Bool]
    private let bridge = OpaquePointer(bitPattern: 0x9000)!
    private let capture = OpaquePointer(bitPattern: 0x9001)!
    private let output = OpaquePointer(bitPattern: 0x9002)!
    private let lock = NSLock()
    private var captureStarted = false
    private var outputStarted = false
    private var captureStartCount = 0
    private var outputStartCount = 0

    init(
        events: PipelineEventRecorder,
        readiness: Readiness = .normal,
        outputStartStatuses: [Bool] = [true, true],
        fadeStatuses: [Bool] = [true]
    ) {
        self.events = events
        self.readiness = readiness
        self.outputStartStatuses = outputStartStatuses
        self.fadeStatuses = fadeStatuses
    }

    func create(
        blackHole: BlackHoleDeviceSnapshot,
        physicalOutput: AudioDeviceSnapshot,
        maximumFrames: UInt32
    ) -> BlackHoleAudioIOResource {
        events.append("io.create")
        return value(generation: blackHole.generation)
    }

    func startCapture(_ resource: BlackHoleAudioIOResource) -> BlackHoleAudioIOResource {
        events.append("io.start.capture")
        lock.withLock {
            captureStarted = true
            captureStartCount += 1
        }
        return value(generation: resource.generation)
    }

    func startOutput(_ resource: BlackHoleAudioIOResource) throws -> BlackHoleAudioIOResource {
        events.append("io.start.output")
        let succeeds = lock.withLock {
            outputStartCount += 1
            return outputStartStatuses.isEmpty ? true : outputStartStatuses.removeFirst()
        }
        guard succeeds else { throw PipelineTestError.injected("output start") }
        lock.withLock { outputStarted = true }
        return value(generation: resource.generation)
    }

    func reset(_ resource: BlackHoleAudioIOResource) {
        events.append("io.reset")
    }

    func fadeOut(_ resource: BlackHoleAudioIOResource) throws {
        events.append("io.fade")
        let succeeds = lock.withLock {
            fadeStatuses.isEmpty ? true : fadeStatuses.removeFirst()
        }
        guard succeeds else { throw PipelineTestError.injected("fade") }
    }

    func cancelFadeOut(_ resource: BlackHoleAudioIOResource) {
        events.append("io.cancel-fade")
    }

    func stopOutput(_ resource: BlackHoleAudioIOResource) -> BlackHoleAudioIOResource {
        events.append("io.stop.output")
        lock.withLock { outputStarted = false }
        return value(generation: resource.generation)
    }

    func stopCapture(_ resource: BlackHoleAudioIOResource) -> BlackHoleAudioIOResource {
        events.append("io.stop.capture")
        lock.withLock { captureStarted = false }
        return value(generation: resource.generation)
    }

    func destroy(_ resource: BlackHoleAudioIOResource) {
        events.append("io.destroy")
    }

    func snapshot(_ resource: BlackHoleAudioIOResource) -> AudioIOBridgeSnapshot {
        let state = lock.withLock {
            (captureStarted, outputStarted, captureStartCount, outputStartCount)
        }
        let preflightCapture = state.0 && state.2 == 1
        let routedCapture = state.0 && state.2 >= 2
        let captureReady = (preflightCapture && readiness != .neverPreflightCapture)
            || (routedCapture && readiness != .neverRoutedCapture)
        let outputReady = state.1
        let snapshotEvent: String
        if outputReady {
            snapshotEvent = "io.snapshot.output-ready"
        } else if preflightCapture {
            snapshotEvent = "io.snapshot.capture-preflight-ready"
        } else {
            snapshotEvent = "io.snapshot.capture-ready"
        }
        events.append(snapshotEvent)
        return AudioIOBridgeSnapshot(
            callbackCount: captureReady ? (preflightCapture ? 1 : 4) : 0,
            frameCount: captureReady ? (preflightCapture ? 512 : 2048) : 0,
            nonZeroSampleCount: 0,
            lastHostTime: captureReady ? 100 : 0,
            maxObservedFrames: 512,
            faultFlags: 0,
            inFlightCallbacks: 0,
            captureCallbackCount: captureReady ? (preflightCapture ? 1 : 4) : 0,
            outputCallbackCount: outputReady ? 1 : 0,
            capturedFrames: captureReady ? (preflightCapture ? 512 : 2048) : 0,
            renderedFrames: outputReady ? 512 : 0,
            ringFillFrames: captureReady ? 1024 : 0
        )
    }

    private func value(generation: AudioGeneration) -> BlackHoleAudioIOResource {
        let state = lock.withLock { (captureStarted, outputStarted) }
        return BlackHoleAudioIOResource(
            descriptor: AudioResourceDescriptor(
                generation: generation,
                kind: .ioProc,
                objectID: 700,
                persistentUID: BlackHoleDeviceSnapshot.expectedUID
            ),
            physicalOutputDeviceID: 600,
            physicalOutputUID: "physical-output",
            bridge: bridge,
            captureRegistration: capture,
            outputUnit: output,
            sampleRate: 48_000,
            isCaptureStarted: state.0,
            isOutputStarted: state.1
        )
    }
}

private enum PipelineTestError: Error {
    case injected(String)
}

private func pipelinePhysicalOutput(generation: AudioGeneration) -> AudioDeviceSnapshot {
    AudioDeviceSnapshot(
        generation: generation,
        objectID: 600,
        uid: "physical-output",
        name: "Physical Output",
        isAlive: true,
        nominalSampleRate: 48_000,
        outputChannelCount: 2,
        outputLayout: AudioBufferLayout(buffers: [.init(index: 0, channelCount: 2)]),
        bufferFrameSize: 512,
        bufferFrameSizeRange: 32...512
    )
}

private func pipelineBlackHole(generation: AudioGeneration) -> BlackHoleDeviceSnapshot {
    let layout = AudioBufferLayout(buffers: [.init(index: 0, channelCount: 2)])
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
    return BlackHoleDeviceSnapshot(
        generation: generation,
        objectID: 700,
        uid: BlackHoleDeviceSnapshot.expectedUID,
        modelUID: BlackHoleDeviceSnapshot.expectedModelUID,
        name: BlackHoleDeviceSnapshot.expectedName,
        manufacturer: BlackHoleDeviceSnapshot.expectedManufacturer,
        transportType: kAudioDeviceTransportTypeVirtual,
        isAlive: true,
        isHidden: false,
        nominalSampleRate: 48_000,
        clockDomain: 0,
        inputLayout: layout,
        outputLayout: layout,
        inputFormat: format,
        outputFormat: format
    )
}

private func pipelineRouteResource(generation: AudioGeneration) -> DefaultAudioRouteResource {
    DefaultAudioRouteResource(
        generation: generation,
        journal: DefaultAudioRouteJournal(
            virtualDeviceUID: BlackHoleDeviceSnapshot.expectedUID,
            originalOutputDeviceUID: "physical-output",
            originalSystemOutputDeviceUID: "physical-system-output"
        )
    )
}

private func XCTAssertThrowsBlackHolePipelineErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected BlackHole pipeline error", file: file, line: line)
    } catch {}
}
