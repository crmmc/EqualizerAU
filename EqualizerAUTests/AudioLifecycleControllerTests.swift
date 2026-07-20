import CoreAudio
import XCTest
@testable import EqualizerAU

final class AudioLifecycleControllerTests: XCTestCase {
    func testLifecycleStartIsIdempotentAndStopReturnsToStopped() async throws {
        let pipeline = LifecyclePipelineStub()
        let controller = AudioLifecycleController(pipeline: pipeline)

        let first = try await controller.start()
        let second = try await controller.start()
        try await controller.stop()
        try await controller.stop()

        let state = await controller.state
        let calls = await pipeline.calls
        XCTAssertEqual(first, second)
        XCTAssertEqual(state, .stopped)
        XCTAssertEqual(calls, ["start:1", "snapshot", "stop"])
    }

    func testLifecycleFailureIsRecoverableAndRetryUsesNewGeneration() async throws {
        let pipeline = LifecyclePipelineStub(startFailures: [LifecycleTestError.injected])
        let controller = AudioLifecycleController(pipeline: pipeline)

        await XCTAssertThrowsErrorAsync(try await controller.start())
        let recovered = try await controller.retry()

        let state = await controller.state
        let calls = await pipeline.calls
        XCTAssertEqual(recovered.generation, AudioGeneration(rawValue: 2))
        XCTAssertEqual(state, .running(AudioGeneration(rawValue: 2)))
        XCTAssertEqual(calls, ["start:1", "stop", "start:2"])
    }

    func testSystemPipelineRollsBackEveryCompletedStartupStage() async {
        for failure in PipelineStageFailure.allCases {
            let harness = PipelineHarness(failure: failure)
            let manager = harness.makeManager()

            await XCTAssertThrowsErrorAsync(
                try await manager.start(generation: AudioGeneration(rawValue: 1))
            )

            let events = await harness.recorder.events
            let snapshot = await manager.snapshot()
            XCTAssertEqual(events, failure.expectedEvents)
            XCTAssertNil(snapshot)
        }
    }

    func testCleanupFailureRetainsDependencyChainForRetry() async throws {
        let harness = PipelineHarness(failure: nil, aggregateDestroyFailures: 1)
        let manager = harness.makeManager()
        _ = try await manager.start(generation: AudioGeneration(rawValue: 1))

        await XCTAssertThrowsErrorAsync(try await manager.stop())
        let hasRetainedResources = await manager.hasPendingResources()
        XCTAssertTrue(hasRetainedResources)
        try await manager.stop()

        let finalSnapshot = await manager.snapshot()
        let hasFinalResources = await manager.hasPendingResources()
        let events = await harness.recorder.events
        XCTAssertNil(finalSnapshot)
        XCTAssertFalse(hasFinalResources)
        XCTAssertEqual(
            events,
            [
                "output", "tap.create", "aggregate.create", "io.create", "io.capture.start",
                "io.output.create", "io.output.start",
                "io.stop", "io.destroy", "aggregate.destroy", "aggregate.destroy", "tap.destroy"
            ]
        )
    }

    func testPendingAggregateRollbackFailureRetainsTapUntilStopRetry() async throws {
        let harness = PipelineHarness(
            failure: .aggregate,
            aggregatePendingCleanupFailures: 1
        )
        let manager = harness.makeManager()

        await XCTAssertThrowsErrorAsync(
            try await manager.start(generation: AudioGeneration(rawValue: 1))
        )
        let retainedAfterStart = await manager.hasPendingResources()
        XCTAssertTrue(retainedAfterStart)

        try await manager.stop()

        let retainedAfterStop = await manager.hasPendingResources()
        let events = await harness.recorder.events
        XCTAssertFalse(retainedAfterStop)
        XCTAssertEqual(
            events,
            [
                "output", "tap.create", "aggregate.create", "aggregate.pending.cleanup",
                "aggregate.pending.cleanup", "tap.destroy"
            ]
        )
    }

    func testPendingTapRollbackFailureIsVisibleAndRetriedWithoutSession() async throws {
        let harness = PipelineHarness(
            failure: .tap,
            tapPendingCleanupFailures: 1
        )
        let manager = harness.makeManager()

        await XCTAssertThrowsErrorAsync(
            try await manager.start(generation: AudioGeneration(rawValue: 1))
        )
        let retainedAfterStart = await manager.hasPendingResources()
        XCTAssertTrue(retainedAfterStart)

        try await manager.stop()

        let retainedAfterStop = await manager.hasPendingResources()
        let events = await harness.recorder.events
        XCTAssertFalse(retainedAfterStop)
        XCTAssertEqual(
            events,
            ["output", "tap.create", "tap.pending.cleanup", "tap.pending.cleanup"]
        )
    }

    func testLifecycleRejectsStartWhileStopIsInFlightAndCoalescesStops() async throws {
        let pipeline = BlockingStopPipelineStub()
        let controller = AudioLifecycleController(pipeline: pipeline)
        _ = try await controller.start()

        let firstStop = Task { try await controller.stop() }
        await pipeline.waitUntilStopEntered()
        let secondStop = Task { try await controller.stop() }

        do {
            _ = try await controller.start()
            XCTFail("Expected start to be rejected while stopping")
        } catch let error as AudioPipelineError {
            guard case .operationInProgress = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        await pipeline.resumeStop()
        try await firstStop.value
        try await secondStop.value

        let stopCalls = await pipeline.stopCalls
        let state = await controller.state
        XCTAssertEqual(stopCalls, 1)
        XCTAssertEqual(state, .stopped)
    }

    func testPipelineManagerClaimsStartBeforeFirstSuspension() async throws {
        let recorder = EventRecorder()
        let output = BlockingOutputStub()
        let manager = SystemAudioPipelineManager(
            outputDiscovery: output,
            tapController: TapStub(recorder: recorder, createFails: false),
            aggregateController: AggregateStub(
                recorder: recorder,
                createFails: false,
                destroyFailures: 0,
                pendingCleanupFailures: 0
            ),
            ioController: IOStub(
                recorder: recorder,
                createFails: false,
                captureStartFails: false,
                outputCreateFails: false,
                outputStartFails: false
            ),
            debugLogger: NullAudioDebugLogger(),
            signalEvidenceRecorder: NullAudioSignalEvidenceRecorder()
        )

        let firstStart = Task {
            try await manager.start(generation: AudioGeneration(rawValue: 1))
        }
        await output.waitUntilRequested()

        do {
            _ = try await manager.start(generation: AudioGeneration(rawValue: 2))
            XCTFail("Expected concurrent manager start to be rejected")
        } catch let error as AudioPipelineError {
            guard case .operationInProgress = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        await output.resume()
        _ = try await firstStart.value
        try await manager.stop()
    }

    func testSnapshotReturnsNilWhenStopDestroysIOBetweenDiagnosticReads() async throws {
        let recorder = EventRecorder()
        let io = IOStub(
            recorder: recorder,
            createFails: false,
            captureStartFails: false,
            outputCreateFails: false,
            outputStartFails: false,
            blockSecondSnapshot: true
        )
        let manager = SystemAudioPipelineManager(
            outputDiscovery: OutputStub(recorder: recorder, shouldFail: false),
            tapController: TapStub(recorder: recorder, createFails: false),
            aggregateController: AggregateStub(
                recorder: recorder,
                createFails: false,
                destroyFailures: 0,
                pendingCleanupFailures: 0
            ),
            ioController: io,
            debugLogger: NullAudioDebugLogger(),
            signalEvidenceRecorder: NullAudioSignalEvidenceRecorder()
        )
        _ = try await manager.start(generation: AudioGeneration(rawValue: 1))

        let snapshot = Task { await manager.snapshot() }
        await io.waitUntilSecondSnapshotEntered()
        let stop = Task { try await manager.stop() }
        await io.waitUntilDestroyed()
        await io.resumeSecondSnapshot()

        let snapshotValue = await snapshot.value
        XCTAssertNil(snapshotValue)
        try await stop.value
    }

    func testSnapshotReturnsNilWhenStopFinishesDuringEvidenceRecording() async throws {
        let recorder = EventRecorder()
        let evidence = BlockingEvidenceRecorder(blockCall: 2)
        let io = IOStub(
            recorder: recorder,
            createFails: false,
            captureStartFails: false,
            outputCreateFails: false,
            outputStartFails: false
        )
        let manager = SystemAudioPipelineManager(
            outputDiscovery: OutputStub(recorder: recorder, shouldFail: false),
            tapController: TapStub(recorder: recorder, createFails: false),
            aggregateController: AggregateStub(
                recorder: recorder,
                createFails: false,
                destroyFailures: 0,
                pendingCleanupFailures: 0
            ),
            ioController: io,
            debugLogger: NullAudioDebugLogger(),
            signalEvidenceRecorder: evidence
        )
        _ = try await manager.start(generation: AudioGeneration(rawValue: 1))

        let snapshot = Task { await manager.snapshot() }
        await evidence.waitUntilBlocked()
        let stop = Task { try await manager.stop() }
        await io.waitUntilDestroyed()
        await evidence.resume()

        let snapshotValue = await snapshot.value
        XCTAssertNil(snapshotValue)
        try await stop.value
    }
}

private enum LifecycleTestError: Error {
    case injected
}

private actor LifecyclePipelineStub: AudioPipelineManaging {
    private var startFailures: [Error]
    private var active: AudioPipelineSnapshot?
    private(set) var calls: [String] = []

    init(startFailures: [Error] = []) {
        self.startFailures = startFailures
    }

    func start(generation: AudioGeneration) throws -> AudioPipelineSnapshot {
        calls.append("start:\(generation.rawValue)")
        if !startFailures.isEmpty { throw startFailures.removeFirst() }
        let snapshot = AudioPipelineSnapshot.fixture(generation: generation)
        active = snapshot
        return snapshot
    }

    func stop() {
        calls.append("stop")
        active = nil
    }

    func snapshot() -> AudioPipelineSnapshot? {
        calls.append("snapshot")
        return active
    }
}

private actor BlockingStopPipelineStub: AudioPipelineManaging {
    private var active: AudioPipelineSnapshot?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var stopCalls = 0

    func start(generation: AudioGeneration) -> AudioPipelineSnapshot {
        let snapshot = AudioPipelineSnapshot.fixture(generation: generation)
        active = snapshot
        return snapshot
    }

    func stop() async {
        stopCalls += 1
        let waiters = stopWaiters
        stopWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            stopContinuation = continuation
        }
        active = nil
    }

    func snapshot() -> AudioPipelineSnapshot? { active }

    func waitUntilStopEntered() async {
        if stopCalls > 0 { return }
        await withCheckedContinuation { continuation in
            stopWaiters.append(continuation)
        }
    }

    func resumeStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }
}

private enum PipelineStageFailure: CaseIterable {
    case output
    case tap
    case aggregate
    case ioCreate
    case ioCaptureStart
    case ioOutputCreate
    case ioOutputStart

    var expectedEvents: [String] {
        switch self {
        case .output: return ["output"]
        case .tap: return ["output", "tap.create", "tap.pending.cleanup"]
        case .aggregate:
            return ["output", "tap.create", "aggregate.create", "aggregate.pending.cleanup", "tap.destroy"]
        case .ioCreate:
            return ["output", "tap.create", "aggregate.create", "io.create", "aggregate.destroy", "tap.destroy"]
        case .ioCaptureStart:
            return [
                "output", "tap.create", "aggregate.create", "io.create", "io.capture.start",
                "io.stop", "io.destroy", "aggregate.destroy", "tap.destroy"
            ]
        case .ioOutputCreate:
            return [
                "output", "tap.create", "aggregate.create", "io.create", "io.capture.start",
                "io.output.create", "io.stop", "io.destroy", "aggregate.destroy", "tap.destroy"
            ]
        case .ioOutputStart:
            return [
                "output", "tap.create", "aggregate.create", "io.create", "io.capture.start",
                "io.output.create", "io.output.start",
                "io.stop", "io.destroy", "aggregate.destroy", "tap.destroy"
            ]
        }
    }
}

private actor EventRecorder {
    private(set) var events: [String] = []
    func append(_ event: String) { events.append(event) }
}

private actor BlockingEvidenceRecorder: AudioSignalEvidenceRecording {
    private let blockCall: Int
    private var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(blockCall: Int) {
        self.blockCall = blockCall
    }

    func record(
        windows: [AudioSignalProbeWindow],
        generation: AudioGeneration,
        logger: any AudioDebugLogging
    ) async {
        calls += 1
        guard calls == blockCall else { return }
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilBlocked() async {
        if calls >= blockCall { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private struct PipelineHarness {
    let recorder = EventRecorder()
    let failure: PipelineStageFailure?
    let aggregateDestroyFailures: Int
    let aggregatePendingCleanupFailures: Int
    let tapPendingCleanupFailures: Int

    init(
        failure: PipelineStageFailure?,
        aggregateDestroyFailures: Int = 0,
        aggregatePendingCleanupFailures: Int = 0,
        tapPendingCleanupFailures: Int = 0
    ) {
        self.failure = failure
        self.aggregateDestroyFailures = aggregateDestroyFailures
        self.aggregatePendingCleanupFailures = aggregatePendingCleanupFailures
        self.tapPendingCleanupFailures = tapPendingCleanupFailures
    }

    func makeManager() -> SystemAudioPipelineManager {
        SystemAudioPipelineManager(
            outputDiscovery: OutputStub(recorder: recorder, shouldFail: failure == .output),
            tapController: TapStub(
                recorder: recorder,
                createFails: failure == .tap,
                pendingCleanupFailures: tapPendingCleanupFailures
            ),
            aggregateController: AggregateStub(
                recorder: recorder,
                createFails: failure == .aggregate,
                destroyFailures: aggregateDestroyFailures,
                pendingCleanupFailures: aggregatePendingCleanupFailures
            ),
            ioController: IOStub(
                recorder: recorder,
                createFails: failure == .ioCreate,
                captureStartFails: failure == .ioCaptureStart,
                outputCreateFails: failure == .ioOutputCreate,
                outputStartFails: failure == .ioOutputStart
            ),
            debugLogger: NullAudioDebugLogger(),
            signalEvidenceRecorder: NullAudioSignalEvidenceRecorder()
        )
    }
}

private struct OutputStub: DefaultOutputDeviceDiscovering {
    let recorder: EventRecorder
    let shouldFail: Bool

    func snapshot(generation: AudioGeneration) async throws -> AudioDeviceSnapshot {
        await recorder.append("output")
        if shouldFail { throw LifecycleTestError.injected }
        return AudioDeviceSnapshot(
            generation: generation,
            objectID: 42,
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
}

private actor BlockingOutputStub: DefaultOutputDeviceDiscovering {
    private var requested = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func snapshot(generation: AudioGeneration) async -> AudioDeviceSnapshot {
        requested = true
        let waiters = requestWaiters
        requestWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return AudioDeviceSnapshot(
            generation: generation,
            objectID: 42,
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

    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor TapStub: ProcessTapControlling {
    let recorder: EventRecorder
    let createFails: Bool
    var pendingCreation = false
    var pendingCleanupFailures: Int

    init(recorder: EventRecorder, createFails: Bool, pendingCleanupFailures: Int = 0) {
        self.recorder = recorder
        self.createFails = createFails
        self.pendingCleanupFailures = pendingCleanupFailures
    }

    func currentProcessObjectID() async -> AudioObjectID { 600 }

    func outputState(processObjectID: AudioObjectID) async -> CoreAudioProcessOutputState {
        CoreAudioProcessOutputState(
            processObjectID: processObjectID,
            isRunningOutput: true,
            outputDeviceIDs: [42]
        )
    }

    func activeOutputProcessObjectIDs(deviceID: AudioObjectID) async -> [AudioObjectID] { [] }

    func create(configuration: ProcessTapConfiguration) async throws -> ProcessTapResource {
        XCTAssertEqual(configuration.muteBehavior, .muted)
        XCTAssertEqual(configuration.outputDeviceUID, "test.output")
        XCTAssertEqual(configuration.outputStreamIndex, 0)
        XCTAssertNil(configuration.includedProcessObjectIDs)
        await recorder.append("tap.create")
        if createFails {
            pendingCreation = true
            throw LifecycleTestError.injected
        }
        return lifecycleTap(generation: configuration.generation)
    }

    func destroy(_ resource: ProcessTapResource) async {
        await recorder.append("tap.destroy")
    }

    func cleanupPendingCreation() async throws {
        guard pendingCreation else { return }
        await recorder.append("tap.pending.cleanup")
        if pendingCleanupFailures > 0 {
            pendingCleanupFailures -= 1
            throw LifecycleTestError.injected
        }
        pendingCreation = false
    }
}

private actor AggregateStub: AggregateDeviceControlling {
    let recorder: EventRecorder
    let createFails: Bool
    var destroyFailures: Int
    var pendingCleanupFailures: Int
    var pendingCreation = false

    init(
        recorder: EventRecorder,
        createFails: Bool,
        destroyFailures: Int,
        pendingCleanupFailures: Int
    ) {
        self.recorder = recorder
        self.createFails = createFails
        self.destroyFailures = destroyFailures
        self.pendingCleanupFailures = pendingCleanupFailures
    }

    func create(
        configuration: AggregateDeviceConfiguration,
        output: AudioDeviceSnapshot,
        tap: ProcessTapResource
    ) async throws -> AggregateDeviceResource {
        await recorder.append("aggregate.create")
        if createFails {
            pendingCreation = true
            throw LifecycleTestError.injected
        }
        return lifecycleAggregate(generation: configuration.generation)
    }

    func destroy(_ resource: AggregateDeviceResource) async throws {
        await recorder.append("aggregate.destroy")
        if destroyFailures > 0 {
            destroyFailures -= 1
            throw LifecycleTestError.injected
        }
    }

    func cleanupPendingCreation() async throws {
        guard pendingCreation else { return }
        await recorder.append("aggregate.pending.cleanup")
        if pendingCleanupFailures > 0 {
            pendingCleanupFailures -= 1
            throw LifecycleTestError.injected
        }
        pendingCreation = false
    }
}

private actor IOStub: AudioIOControlling {
    let recorder: EventRecorder
    let createFails: Bool
    let captureStartFails: Bool
    let outputCreateFails: Bool
    let outputStartFails: Bool
    let blockSecondSnapshot: Bool
    private var active = false
    private var snapshotCalls = 0
    private var snapshotContinuation: CheckedContinuation<Void, Never>?
    private var snapshotEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var destroyWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        recorder: EventRecorder,
        createFails: Bool,
        captureStartFails: Bool,
        outputCreateFails: Bool,
        outputStartFails: Bool,
        blockSecondSnapshot: Bool = false
    ) {
        self.recorder = recorder
        self.createFails = createFails
        self.captureStartFails = captureStartFails
        self.outputCreateFails = outputCreateFails
        self.outputStartFails = outputStartFails
        self.blockSecondSnapshot = blockSecondSnapshot
    }

    func create(
        aggregate: AggregateDeviceResource,
        tap: ProcessTapResource,
        output: AudioDeviceSnapshot,
        maxFrames: UInt32
    ) async throws -> AudioIOResource {
        await recorder.append("io.create")
        if createFails { throw LifecycleTestError.injected }
        active = true
        return lifecycleIO(generation: aggregate.descriptor.generation)
    }

    func startCapture(_ resource: AudioIOResource) async throws -> AudioIOResource {
        XCTAssertFalse(resource.isCaptureStarted)
        XCTAssertNil(resource.outputRegistration)
        await recorder.append("io.capture.start")
        if captureStartFails { throw LifecycleTestError.injected }
        return lifecycleIO(
            generation: resource.descriptor.generation,
            ownershipToken: resource.ownershipToken,
            isCaptureStarted: true
        )
    }

    func createOutput(_ resource: AudioIOResource) async throws -> AudioIOResource {
        XCTAssertTrue(resource.isCaptureStarted)
        XCTAssertNil(resource.outputRegistration)
        await recorder.append("io.output.create")
        if outputCreateFails { throw LifecycleTestError.injected }
        return lifecycleIO(
            generation: resource.descriptor.generation,
            ownershipToken: resource.ownershipToken,
            outputRegistration: OpaquePointer(bitPattern: 0x2345),
            isCaptureStarted: true
        )
    }

    func startOutput(_ resource: AudioIOResource) async throws -> AudioIOResource {
        XCTAssertTrue(resource.isCaptureStarted)
        XCTAssertNotNil(resource.outputRegistration)
        XCTAssertFalse(resource.isOutputStarted)
        await recorder.append("io.output.start")
        if outputStartFails { throw LifecycleTestError.injected }
        return lifecycleIO(
            generation: resource.descriptor.generation,
            ownershipToken: resource.ownershipToken,
            outputRegistration: resource.outputRegistration,
            isCaptureStarted: true,
            isOutputStarted: true
        )
    }

    func stop(_ resource: AudioIOResource) async -> AudioIOResource {
        await recorder.append("io.stop")
        return lifecycleIO(
            generation: resource.descriptor.generation,
            ownershipToken: resource.ownershipToken,
            outputRegistration: resource.outputRegistration
        )
    }

    func destroy(_ resource: AudioIOResource) async {
        XCTAssertFalse(resource.isCaptureStarted)
        XCTAssertFalse(resource.isOutputStarted)
        active = false
        await recorder.append("io.destroy")
        let waiters = destroyWaiters
        destroyWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func snapshot(_ resource: AudioIOResource) async throws -> AudioIOBridgeSnapshot {
        snapshotCalls += 1
        if blockSecondSnapshot, snapshotCalls == 2 {
            let waiters = snapshotEntryWaiters
            snapshotEntryWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { snapshotContinuation = $0 }
        }
        guard active else { throw AudioIOError.staleResource }
        return AudioPipelineSnapshot.fixture().diagnostics
    }

    func signalProbes(_ resource: AudioIOResource) async throws -> [AudioSignalProbeWindow] {
        guard active else { throw AudioIOError.staleResource }
        return []
    }

    func waitUntilSecondSnapshotEntered() async {
        if snapshotCalls >= 2 { return }
        await withCheckedContinuation { snapshotEntryWaiters.append($0) }
    }

    func resumeSecondSnapshot() {
        snapshotContinuation?.resume()
        snapshotContinuation = nil
    }

    func waitUntilDestroyed() async {
        if !active { return }
        await withCheckedContinuation { destroyWaiters.append($0) }
    }
}

private func lifecycleTap(generation: AudioGeneration) -> ProcessTapResource {
    ProcessTapResource(
        descriptor: AudioResourceDescriptor(
            generation: generation,
            kind: .processTap,
            objectID: 700,
            persistentUID: "test.tap"
        ),
        selfProcessObjectID: 600,
        format: AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        ),
        muteBehavior: .muted
    )
}

private func lifecycleAggregate(generation: AudioGeneration) -> AggregateDeviceResource {
    AggregateDeviceResource(
        descriptor: AudioResourceDescriptor(
            generation: generation,
            kind: .aggregateDevice,
            objectID: 800,
            persistentUID: "test.aggregate"
        ),
        outputDeviceUID: "test.output",
        tapUID: "test.tap",
        tapUIDs: ["test.tap"],
        inputLayout: AudioBufferLayout(buffers: [.init(index: 0, channelCount: 2)]),
        inputFormat: AudioStreamBasicDescription(
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
        nominalSampleRate: 48_000,
        maximumFrames: 4_096
    )
}

private func lifecycleIO(
    generation: AudioGeneration,
    ownershipToken: UUID = UUID(),
    outputRegistration: OpaquePointer? = nil,
    isCaptureStarted: Bool = false,
    isOutputStarted: Bool = false
) -> AudioIOResource {
    AudioIOResource(
        descriptor: AudioResourceDescriptor(
            ownershipToken: ownershipToken,
            generation: generation,
            kind: .ioProc,
            objectID: 800,
            persistentUID: "test.aggregate"
        ),
        captureRegistration: OpaquePointer(bitPattern: 0x1234)!,
        outputRegistration: outputRegistration,
        bridge: OpaquePointer(bitPattern: 0x5678)!,
        sampleRate: 48_000,
        isCaptureStarted: isCaptureStarted,
        isOutputStarted: isOutputStarted
    )
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}
