import CoreAudio
import XCTest
@testable import EqualizerAU

final class AppModelTests: XCTestCase {
    @MainActor
    func testInitialStateIsStopped() {
        let model = AppModel(lifecycle: AudioLifecycleController(pipeline: PipelineStub()))

        XCTAssertEqual(model.permissionState, .notDetermined)
        XCTAssertEqual(model.audioState, .stopped)
        XCTAssertEqual(model.outputDeviceName, "Not queried")
        XCTAssertEqual(model.tapUID, "Not queried")
        XCTAssertEqual(model.tapFormat, "Not queried")
        XCTAssertNil(model.lastError)
    }

    @MainActor
    func testSuccessfulStartPublishesRunningPipelineWithoutPrematurePermissionClaim() async {
        let model = AppModel(lifecycle: AudioLifecycleController(pipeline: PipelineStub()))

        model.start()
        await waitUntil(model) { $0.audioState == .running }

        XCTAssertEqual(model.permissionState, .tapCreated)
        XCTAssertEqual(model.outputDeviceName, "Test Output (48000 Hz, 2 ch)")
        XCTAssertEqual(model.tapUID, "test-tap-uid")
        XCTAssertEqual(model.tapFormat, "48000 Hz, 2 ch, 'lpcm'")
        XCTAssertNil(model.lastError)
    }

    @MainActor
    func testFailedStartPublishesStructuredError() async {
        let pipeline = PipelineStub(startError: TestFailure.start)
        let model = AppModel(lifecycle: AudioLifecycleController(pipeline: pipeline))

        model.start()
        await waitUntil(model) { $0.audioState == .failed }

        XCTAssertEqual(model.permissionState, .notDetermined)
        XCTAssertEqual(model.lastError, TestFailure.start.localizedDescription)
    }

    @MainActor
    func testStopDuringStartWaitsForTransactionThenStopsPipeline() async {
        let pipeline = PipelineStub(startDelay: .milliseconds(20))
        let model = AppModel(lifecycle: AudioLifecycleController(pipeline: pipeline))

        model.start()
        model.stop()
        await waitUntil(model) { $0.audioState == .stopped }

        let calls = await pipeline.calls
        XCTAssertEqual(calls, ["start:1", "stop"])
        XCTAssertNil(model.lastError)
    }

    @MainActor
    func testOutputIsolationCanBeCancelledFromThePrimaryControl() async {
        let isolation = CancellableOutputIsolationStub()
        let model = AppModel(
            lifecycle: AudioLifecycleController(pipeline: PipelineStub()),
            outputIsolation: isolation
        )

        model.runOutputIsolationTest()
        XCTAssertEqual(model.outputIsolationState, .running)

        model.cancelOutputIsolationTest()
        await waitUntil(model) { $0.outputIsolationState == .idle }

        XCTAssertEqual(model.outputIsolationSummary, "Stopped")
        XCTAssertNil(model.lastError)
        let cancelCalls = await isolation.cancelCalls
        XCTAssertEqual(cancelCalls, 1)
    }

    @MainActor
    func testMissingBlackHoleDisablesVirtualRouteWithoutPublishingAnError() async {
        let model = AppModel(
            lifecycle: AudioLifecycleController(pipeline: PipelineStub()),
            blackHoleDiscovery: MissingBlackHoleDiscovery(),
            virtualRouteLifecycle: BlackHoleAudioLifecycleController(
                pipeline: VirtualPipelineStub()
            )
        )

        model.refreshVirtualRoutePrerequisite()
        await waitUntil(model) { $0.virtualRouteState == .missing }

        XCTAssertEqual(
            model.virtualRouteSummary,
            "Install the official BlackHole 2ch device, then refresh"
        )
        XCTAssertNil(model.lastError)
    }

    @MainActor
    func testVirtualRouteStartAndStopPublishOnlyCoreState() async {
        let pipeline = VirtualPipelineStub()
        let model = AppModel(
            lifecycle: AudioLifecycleController(pipeline: PipelineStub()),
            blackHoleDiscovery: ReadyBlackHoleDiscovery(),
            virtualRouteLifecycle: BlackHoleAudioLifecycleController(pipeline: pipeline)
        )

        model.refreshVirtualRoutePrerequisite()
        await waitUntil(model) { $0.virtualRouteState == .ready }
        model.startVirtualRouteProof()
        await waitUntil(model) { $0.virtualRouteState == .running }
        XCTAssertEqual(model.outputDeviceName, "Physical Output (48000 Hz, 2 ch)")

        model.stopVirtualRouteProof()
        await waitUntil(model) { $0.virtualRouteState == .ready }
        XCTAssertEqual(model.virtualRouteSummary, "Stopped; previous system route restored")
        let calls = await pipeline.calls
        XCTAssertEqual(calls, ["start:1", "stop"])
    }

    @MainActor
    private func waitUntil(
        _ model: AppModel,
        condition: (AppModel) -> Bool
    ) async {
        for _ in 0..<200 {
            if condition(model) { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("AppModel did not reach the expected state in bounded time")
    }
}

private enum TestFailure: Error {
    case start
}

private actor PipelineStub: AudioPipelineManaging {
    private let startError: Error?
    private let startDelay: Duration?
    private var activeSnapshot: AudioPipelineSnapshot?
    private(set) var calls: [String] = []

    init(startError: Error? = nil, startDelay: Duration? = nil) {
        self.startError = startError
        self.startDelay = startDelay
    }

    func start(generation: AudioGeneration) async throws -> AudioPipelineSnapshot {
        calls.append("start:\(generation.rawValue)")
        if let startDelay { try await Task.sleep(for: startDelay) }
        if let startError { throw startError }
        let snapshot = AudioPipelineSnapshot.fixture(generation: generation)
        activeSnapshot = snapshot
        return snapshot
    }

    func stop() {
        calls.append("stop")
        activeSnapshot = nil
    }

    func snapshot() -> AudioPipelineSnapshot? {
        activeSnapshot
    }
}

private actor CancellableOutputIsolationStub: AudioOutputIsolationRunning {
    private var cancelled = false
    private(set) var cancelCalls = 0

    func run() async throws -> AudioOutputIsolationResult {
        while !cancelled {
            try await Task.sleep(for: .milliseconds(1))
        }
        throw AudioOutputIsolationError.cancelled
    }

    func cancel() {
        cancelCalls += 1
        cancelled = true
    }
}

private struct MissingBlackHoleDiscovery: BlackHoleDeviceDiscovering {
    func snapshot(generation: AudioGeneration) async throws -> BlackHoleDeviceSnapshot {
        throw BlackHoleDeviceDiscoveryError.notInstalled(uid: BlackHoleDeviceSnapshot.expectedUID)
    }
}

private struct ReadyBlackHoleDiscovery: BlackHoleDeviceDiscovering {
    func snapshot(generation: AudioGeneration) async throws -> BlackHoleDeviceSnapshot {
        appModelBlackHoleFixture(generation: generation)
    }
}

private actor VirtualPipelineStub: BlackHoleAudioPipelineManaging {
    private(set) var calls: [String] = []
    private var active: BlackHoleAudioPipelineSnapshot?

    func start(generation: AudioGeneration) -> BlackHoleAudioPipelineSnapshot {
        calls.append("start:\(generation.rawValue)")
        let snapshot = BlackHoleAudioPipelineSnapshot(
            generation: generation,
            physicalOutputName: "Physical Output (48000 Hz, 2 ch)",
            virtualDeviceName: BlackHoleDeviceSnapshot.expectedName,
            routeActive: true,
            diagnostics: AudioIOBridgeSnapshot(
                callbackCount: 1,
                frameCount: 512,
                nonZeroSampleCount: 1,
                lastHostTime: 1,
                maxObservedFrames: 512,
                faultFlags: 0,
                inFlightCallbacks: 0
            )
        )
        active = snapshot
        return snapshot
    }

    func stop() {
        calls.append("stop")
        active = nil
    }

    func snapshot() -> BlackHoleAudioPipelineSnapshot? { active }
}

private func appModelBlackHoleFixture(generation: AudioGeneration) -> BlackHoleDeviceSnapshot {
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

extension AudioPipelineSnapshot {
    static func fixture(
        generation: AudioGeneration = AudioGeneration(rawValue: 1),
        nonZeroSampleCount: UInt64 = 0
    ) -> AudioPipelineSnapshot {
        AudioPipelineSnapshot(
            generation: generation,
            outputDeviceName: "Test Output (48000 Hz, 2 ch)",
            tapUID: "test-tap-uid",
            tapFormat: "48000 Hz, 2 ch, 'lpcm'",
            diagnostics: AudioIOBridgeSnapshot(
                callbackCount: 0,
                frameCount: 0,
                nonZeroSampleCount: nonZeroSampleCount,
                lastHostTime: 0,
                maxObservedFrames: 0,
                faultFlags: 0,
                inFlightCallbacks: 0
            )
        )
    }
}
