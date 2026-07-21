import Foundation
import XCTest

final class M1AudioRouteResourceControllerTests: XCTestCase {
    func testProductionTapAndAggregateRequestsAndReadbacksAreStrict() async throws {
        let hal = TestHALRouteOperations()
        let controller = M1AudioRouteResourceController(operations: hal)
        let generation = M1AudioRouteGeneration(rawValue: 1)
        let output = try await controller.discoverOutput(generation: generation)
        let tap = try await controller.createTap(generation: generation, output: output)
        let aggregate = try await controller.createAggregate(
            generation: generation,
            output: output,
            tap: tap
        )

        XCTAssertEqual(hal.tapRequests.count, 1)
        let tapRequest = try XCTUnwrap(hal.tapRequests.first)
        XCTAssertEqual(tapRequest.outputDeviceUID, "device.uid")
        XCTAssertEqual(tapRequest.outputStreamIndex, 0)
        XCTAssertEqual(tapRequest.excludedProcessObjectID, 77)
        XCTAssertTrue(tapRequest.isPrivate)
        XCTAssertTrue(tapRequest.isMuted)
        XCTAssertEqual(aggregate.outputDeviceUID, output.uid)

        XCTAssertEqual(hal.aggregateRequests.count, 1)
        let aggregateRequest = try XCTUnwrap(hal.aggregateRequests.first)
        XCTAssertTrue(aggregateRequest.isPrivate)
        XCTAssertFalse(aggregateRequest.isStacked)
        XCTAssertFalse(aggregateRequest.tapAutoStart)
        XCTAssertTrue(aggregateRequest.tapDriftCompensation)
        XCTAssertEqual(aggregateRequest.tapUID, tap.descriptor.persistentUID)
    }

    func testTapValidationRollbackFailureIsRetainedAndRetryable() async throws {
        let hal = TestHALRouteOperations()
        hal.tapData = M1HALTapData(uid: "", format: hal.supportedFormat)
        hal.tapDestroyFailuresRemaining = 1
        let controller = M1AudioRouteResourceController(operations: hal)
        let generation = M1AudioRouteGeneration(rawValue: 2)
        let output = try await controller.discoverOutput(generation: generation)

        do {
            _ = try await controller.createTap(generation: generation, output: output)
            XCTFail("invalid tap must fail")
        } catch let error as M1AudioRouteError {
            XCTAssertEqual(error, .invalidTap("unsupported tap UID or format"))
        }
        let pendingAfterFailure = await controller.hasPendingResources()
        XCTAssertTrue(pendingAfterFailure)
        XCTAssertEqual(hal.destroyedTapIDs, [101])

        try await controller.cleanupPendingResources()
        let pendingAfterRetry = await controller.hasPendingResources()
        XCTAssertFalse(pendingAfterRetry)
        XCTAssertEqual(hal.destroyedTapIDs, [101, 101])
    }

    func testActiveTapRejectsSecondCreationBeforeCallingHAL() async throws {
        let hal = TestHALRouteOperations()
        let controller = M1AudioRouteResourceController(operations: hal)
        let generation = M1AudioRouteGeneration(rawValue: 3)
        let output = try await controller.discoverOutput(generation: generation)
        _ = try await controller.createTap(generation: generation, output: output)

        do {
            _ = try await controller.createTap(generation: generation, output: output)
            XCTFail("second active tap must be rejected")
        } catch let error as M1AudioRouteError {
            XCTAssertEqual(error, .staleResource)
        }
        XCTAssertEqual(hal.tapRequests.count, 1)
    }

    func testAggregateIsDestroyedBeforeTap() async throws {
        let hal = TestHALRouteOperations()
        let controller = M1AudioRouteResourceController(operations: hal)
        let generation = M1AudioRouteGeneration(rawValue: 4)
        let output = try await controller.discoverOutput(generation: generation)
        let tap = try await controller.createTap(generation: generation, output: output)
        let aggregate = try await controller.createAggregate(
            generation: generation,
            output: output,
            tap: tap
        )

        try await controller.destroyAggregate(aggregate)
        try await controller.destroyTap(tap)
        XCTAssertEqual(hal.destroyOrder, ["aggregate:202", "tap:101"])
    }

    func testDestroyedTapCannotCreateAggregate() async throws {
        let hal = TestHALRouteOperations()
        let controller = M1AudioRouteResourceController(operations: hal)
        let generation = M1AudioRouteGeneration(rawValue: 5)
        let output = try await controller.discoverOutput(generation: generation)
        let tap = try await controller.createTap(generation: generation, output: output)
        try await controller.destroyTap(tap)

        do {
            _ = try await controller.createAggregate(
                generation: generation,
                output: output,
                tap: tap
            )
            XCTFail("destroyed tap must be rejected")
        } catch let error as M1AudioRouteError {
            XCTAssertEqual(error, .staleResource)
        }
        XCTAssertTrue(hal.aggregateRequests.isEmpty)
    }

    func testWrongKindTapCannotCreateAggregate() async throws {
        let hal = TestHALRouteOperations()
        let controller = M1AudioRouteResourceController(operations: hal)
        let generation = M1AudioRouteGeneration(rawValue: 6)
        let output = try await controller.discoverOutput(generation: generation)
        let tap = try await controller.createTap(generation: generation, output: output)
        let wrongKindTap = M1ProcessTapResource(
            descriptor: M1HALResourceDescriptor(
                ownershipToken: tap.descriptor.ownershipToken,
                generation: generation,
                kind: .aggregateDevice,
                objectID: tap.descriptor.objectID,
                persistentUID: tap.descriptor.persistentUID
            ),
            excludedProcessObjectID: tap.excludedProcessObjectID,
            outputDeviceUID: tap.outputDeviceUID,
            format: tap.format
        )

        do {
            _ = try await controller.createAggregate(
                generation: generation,
                output: output,
                tap: wrongKindTap
            )
            XCTFail("wrong-kind tap must be rejected")
        } catch let error as M1AudioRouteError {
            XCTAssertEqual(error, .staleResource)
        }
        XCTAssertTrue(hal.aggregateRequests.isEmpty)
    }

    func testRuntimeInstallFailureDestroysUninstalledRouteInDependencyOrder() async throws {
        let hal = TestHALRouteOperations()
        let routeResources = M1AudioRouteResourceController(operations: hal)
        let audioIO = M1AudioIOController(
            operations: UnexpectedAudioIOOperations(),
            timing: M1AudioIOControlTiming(
                nowNanoseconds: { 0 },
                sleep: { _ in }
            )
        )
        let runtimeFactory = TestRuntimeFactory()
        let runtimeAccess = M1RuntimeLeaseAccess(stopHandler: { _, _ in })
        let existingRuntime = M1RuntimeHandleLease(
            bridgeGeneration: 999,
            pointer: OpaquePointer(bitPattern: 0x2000)!
        )
        let existingRuntimeInstalled = await runtimeAccess.install(existingRuntime)
        XCTAssertTrue(existingRuntimeInstalled)
        let maintenance = M1RetirementMaintenanceCoordinator(
            access: runtimeAccess,
            timing: M1RetirementMaintenanceTiming(
                nowNanoseconds: { 0 },
                sleep: { _ in }
            )
        )
        let coordinator = M1NativeAudioRouteCoordinator(
            routeResources: routeResources,
            audioIO: audioIO,
            runtimeFactory: runtimeFactory,
            runtimeAccess: runtimeAccess,
            retirementMaintenance: maintenance
        )

        do {
            try await coordinator.start()
            XCTFail("preinstalled runtime lease must reject route start")
        } catch let error as M1AudioIOError {
            XCTAssertEqual(error, .invalidState("runtime lease is already installed"))
        }

        XCTAssertEqual(runtimeFactory.destroyedBridgeGenerations, [1])
        XCTAssertEqual(hal.destroyOrder, ["aggregate:202", "tap:101"])
        let state = await coordinator.state()
        let retainedExistingRuntime = await runtimeAccess.invalidate(bridgeGeneration: 999)
        XCTAssertEqual(state, .stopped)
        XCTAssertTrue(retainedExistingRuntime === existingRuntime)
    }

    func testPrepareRejectsMissingIRBeforeOutputDiscovery() async throws {
        let hal = TestHALRouteOperations()
        let runtimeAccess = M1RuntimeLeaseAccess(stopHandler: { _, _ in })
        let coordinator = M1NativeAudioRouteCoordinator(
            routeResources: M1AudioRouteResourceController(operations: hal),
            audioIO: M1AudioIOController(
                operations: UnexpectedAudioIOOperations(),
                timing: M1AudioIOControlTiming(nowNanoseconds: { 0 }, sleep: { _ in })
            ),
            runtimeFactory: TestRuntimeFactory(),
            runtimeAccess: runtimeAccess,
            retirementMaintenance: M1RetirementMaintenanceCoordinator(
                access: runtimeAccess,
                timing: M1RetirementMaintenanceTiming(nowNanoseconds: { 0 }, sleep: { _ in })
            ),
            irLoader: M1ConvolutionIRStore(
                directoryURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("missing-ir-\(UUID().uuidString)")
            )
        )
        let ir = M1ConvolutionIRReference(
            storageID: UUID(),
            originalFileName: "missing.wav",
            sha256: String(repeating: "0", count: 64),
            sampleRate: 48_000,
            channelCount: 1,
            frameCount: 1
        )
        let node = M1ProcessingNode.convolution(ir: ir)
        let configuration = M1ConfigurationSnapshot(effectsEnabled: true, nodes: [node])

        do {
            _ = try await coordinator.prepare(configuration: configuration)
            XCTFail("missing IR must fail before waiting for output")
        } catch let error as M1ProcessingBuildError {
            XCTAssertEqual(
                error,
                .convolutionIRLoadFailed(nodeID: node.id, error: .missingResource)
            )
        }
        XCTAssertEqual(hal.defaultOutputReadCount, 0)
    }

    func testPrepareBoundsAndDeduplicatesIRPreflightBeforeUnavailableOutput() async throws {
        let hal = TestHALRouteOperations()
        hal.defaultOutputError = .noOutputDevice
        let loader = CountingIRLoader()
        let runtimeAccess = M1RuntimeLeaseAccess(stopHandler: { _, _ in })
        let coordinator = M1NativeAudioRouteCoordinator(
            routeResources: M1AudioRouteResourceController(operations: hal),
            audioIO: M1AudioIOController(
                operations: UnexpectedAudioIOOperations(),
                timing: M1AudioIOControlTiming(nowNanoseconds: { 0 }, sleep: { _ in })
            ),
            runtimeFactory: TestRuntimeFactory(),
            runtimeAccess: runtimeAccess,
            retirementMaintenance: M1RetirementMaintenanceCoordinator(
                access: runtimeAccess,
                timing: M1RetirementMaintenanceTiming(nowNanoseconds: { 0 }, sleep: { _ in })
            ),
            irLoader: loader
        )
        let ir = M1ConvolutionIRReference(
            storageID: UUID(),
            originalFileName: "shared.wav",
            sha256: String(repeating: "0", count: 64),
            sampleRate: 48_000,
            channelCount: 1,
            frameCount: 1
        )

        let waiting = try await coordinator.prepare(configuration: M1ConfigurationSnapshot(
            effectsEnabled: true,
            nodes: [.convolution(ir: ir), .convolution(ir: ir)]
        ))
        XCTAssertEqual(waiting, .waitingForOutput)
        XCTAssertEqual(loader.validationCount, 1)

        do {
            _ = try await coordinator.prepare(configuration: M1ConfigurationSnapshot(
                effectsEnabled: true,
                nodes: (0...M1ProcessingBuilder.maximumConvolutionStages).map { _ in .convolution(ir: ir) }
            ))
            XCTFail("stage capacity must fail before IR I/O")
        } catch let error as M1ProcessingBuildError {
            XCTAssertEqual(error, .convolutionStageCapacityExceeded)
        }
        XCTAssertEqual(loader.validationCount, 1)
    }

    func testCancellingPrepareCancelsDetachedIRPreflightBeforeOutputDiscovery() async throws {
        let entered = expectation(description: "IR validation entered")
        let hal = TestHALRouteOperations()
        let loader = CancellationObservingIRLoader { entered.fulfill() }
        let runtimeAccess = M1RuntimeLeaseAccess(stopHandler: { _, _ in })
        let coordinator = M1NativeAudioRouteCoordinator(
            routeResources: M1AudioRouteResourceController(operations: hal),
            audioIO: M1AudioIOController(
                operations: UnexpectedAudioIOOperations(),
                timing: M1AudioIOControlTiming(nowNanoseconds: { 0 }, sleep: { _ in })
            ),
            runtimeFactory: TestRuntimeFactory(),
            runtimeAccess: runtimeAccess,
            retirementMaintenance: M1RetirementMaintenanceCoordinator(
                access: runtimeAccess,
                timing: M1RetirementMaintenanceTiming(nowNanoseconds: { 0 }, sleep: { _ in })
            ),
            irLoader: loader
        )
        let ir = M1ConvolutionIRReference(
            storageID: UUID(),
            originalFileName: "cancel.wav",
            sha256: String(repeating: "0", count: 64),
            sampleRate: 48_000,
            channelCount: 1,
            frameCount: 1
        )
        let prepare = Task {
            try await coordinator.prepare(configuration: M1ConfigurationSnapshot(
                effectsEnabled: true,
                nodes: [.convolution(ir: ir)]
            ))
        }

        await fulfillment(of: [entered], timeout: 1)
        prepare.cancel()
        do {
            _ = try await prepare.value
            XCTFail("cancelled prepare must fail")
        } catch is CancellationError {}
        XCTAssertEqual(hal.defaultOutputReadCount, 0)
    }

    func testCancellingPrepareCancelsDetachedIRCompileAfterOutputDiscovery() async throws {
        let entered = expectation(description: "IR compile load entered")
        let hal = TestHALRouteOperations()
        let loader = CompileCancellationObservingIRLoader { entered.fulfill() }
        let runtimeAccess = M1RuntimeLeaseAccess(stopHandler: { _, _ in })
        let coordinator = M1NativeAudioRouteCoordinator(
            routeResources: M1AudioRouteResourceController(operations: hal),
            audioIO: M1AudioIOController(
                operations: UnexpectedAudioIOOperations(),
                timing: M1AudioIOControlTiming(nowNanoseconds: { 0 }, sleep: { _ in })
            ),
            runtimeFactory: TestRuntimeFactory(),
            runtimeAccess: runtimeAccess,
            retirementMaintenance: M1RetirementMaintenanceCoordinator(
                access: runtimeAccess,
                timing: M1RetirementMaintenanceTiming(nowNanoseconds: { 0 }, sleep: { _ in })
            ),
            irLoader: loader
        )
        let ir = M1ConvolutionIRReference(
            storageID: UUID(),
            originalFileName: "cancel-compile.wav",
            sha256: String(repeating: "0", count: 64),
            sampleRate: 48_000,
            channelCount: 1,
            frameCount: 1
        )
        let prepare = Task {
            try await coordinator.prepare(configuration: M1ConfigurationSnapshot(
                effectsEnabled: true,
                nodes: [.convolution(ir: ir)]
            ))
        }

        await fulfillment(of: [entered], timeout: 1)
        prepare.cancel()
        do {
            _ = try await prepare.value
            XCTFail("cancelled compile must fail")
        } catch is CancellationError {}
        XCTAssertEqual(hal.defaultOutputReadCount, 1)
    }
}

private final class CountingIRLoader: M1ConvolutionIRLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var _validationCount = 0

    var validationCount: Int {
        lock.withLock { _validationCount }
    }

    func validate(reference: M1ConvolutionIRReference) throws {
        lock.withLock { _validationCount += 1 }
    }

    func load(
        reference: M1ConvolutionIRReference,
        targetSampleRate: Double
    ) throws -> M1LoadedConvolutionIR {
        throw M1ConvolutionIRError.resourceIO
    }
}

private final class CancellationObservingIRLoader: M1ConvolutionIRLoading, @unchecked Sendable {
    private let entered: @Sendable () -> Void

    init(entered: @escaping @Sendable () -> Void) {
        self.entered = entered
    }

    func validate(reference: M1ConvolutionIRReference) throws {
        entered()
        while !Task.isCancelled {
            Thread.sleep(forTimeInterval: 0.001)
        }
        throw CancellationError()
    }

    func load(
        reference: M1ConvolutionIRReference,
        targetSampleRate: Double
    ) throws -> M1LoadedConvolutionIR {
        throw M1ConvolutionIRError.resourceIO
    }
}

private final class CompileCancellationObservingIRLoader: M1ConvolutionIRLoading, @unchecked Sendable {
    private let entered: @Sendable () -> Void

    init(entered: @escaping @Sendable () -> Void) {
        self.entered = entered
    }

    func validate(reference: M1ConvolutionIRReference) throws {}

    func load(
        reference: M1ConvolutionIRReference,
        targetSampleRate: Double
    ) throws -> M1LoadedConvolutionIR {
        entered()
        while !Task.isCancelled {
            Thread.sleep(forTimeInterval: 0.001)
        }
        throw CancellationError()
    }
}

private final class TestHALRouteOperations: M1HALRouteOperations, @unchecked Sendable {
    let supportedFormat = M1HALPCMFormat(
        sampleRate: 48_000,
        channelCount: 2,
        isNativeFloat32: true,
        isPacked: true,
        isNonInterleaved: false,
        framesPerPacket: 1,
        bytesPerFrame: 8,
        bytesPerPacket: 8
    )
    var tapData: M1HALTapData!
    var tapRequests: [M1ProcessTapRequest] = []
    var aggregateRequests: [M1AggregateRequest] = []
    var tapDestroyFailuresRemaining = 0
    var destroyedTapIDs: [UInt32] = []
    var destroyOrder: [String] = []
    var defaultOutputReadCount = 0
    var defaultOutputError: M1AudioRouteError?

    init() {
        tapData = M1HALTapData(uid: "tap.uid", format: supportedFormat)
    }

    func readDefaultOutputDevice() throws -> M1HALOutputDeviceData {
        defaultOutputReadCount += 1
        if let defaultOutputError { throw defaultOutputError }
        return M1HALOutputDeviceData(
            objectID: 42,
            uid: "device.uid",
            name: "Output",
            isAlive: true,
            sampleRate: 48_000,
            maximumFrameCount: 256,
            bufferChannelCounts: [2],
            semanticPositions: [
                M1SpeakerPosition(rawValue: "L"),
                M1SpeakerPosition(rawValue: "R"),
            ]
        )
    }

    func readCurrentProcessObjectID() throws -> UInt32 { 77 }

    func createProcessTap(_ request: M1ProcessTapRequest) throws -> UInt32 {
        tapRequests.append(request)
        return 101
    }

    func readProcessTap(_ objectID: UInt32) throws -> M1HALTapData { tapData }

    func destroyProcessTap(_ objectID: UInt32) throws {
        destroyedTapIDs.append(objectID)
        if tapDestroyFailuresRemaining > 0 {
            tapDestroyFailuresRemaining -= 1
            throw TestFailure.injected
        }
        destroyOrder.append("tap:\(objectID)")
    }

    func createAggregateDevice(_ request: M1AggregateRequest) throws -> UInt32 {
        aggregateRequests.append(request)
        return 202
    }

    func readAggregateDevice(_ objectID: UInt32) throws -> M1HALAggregateData {
        M1HALAggregateData(
            uid: aggregateRequests.last!.uid,
            tapUIDs: [tapData.uid],
            format: supportedFormat,
            maximumFrameCount: 256,
            bufferChannelCounts: [2]
        )
    }

    func destroyAggregateDevice(_ objectID: UInt32) throws {
        destroyOrder.append("aggregate:\(objectID)")
    }
}

private final class TestRuntimeFactory: M1RuntimeCreating, @unchecked Sendable {
    var destroyedBridgeGenerations: [UInt64] = []

    func createRuntime(
        bridgeGeneration: UInt64,
        initialState: M1RuntimeInitialState,
        maximumFrameCount: Int,
        sampleRate: Double
    ) throws -> M1RuntimeHandleLease {
        M1RuntimeHandleLease(
            bridgeGeneration: bridgeGeneration,
            pointer: OpaquePointer(bitPattern: 0x3000)!
        )
    }

    func destroyRuntime(_ runtime: M1RuntimeHandleLease) {
        destroyedBridgeGenerations.append(runtime.bridgeGeneration)
    }
}

private struct UnexpectedAudioIOOperations: M1AudioIOOperations {
    func createHost(
        configuration: M1AudioIOHostConfiguration,
        runtime: M1RuntimeHandleLease
    ) throws -> M1AudioIOHostHandle { throw TestFailure.injected }
    func beginStopping(_ host: M1AudioIOHostHandle) {}
    func requestFadeOut(_ host: M1AudioIOHostHandle, frameCount: Int) {}
    func isFadeComplete(_ host: M1AudioIOHostHandle) -> Bool { false }
    func isQuiescent(_ host: M1AudioIOHostHandle) -> Bool { false }
    func hostDiagnostics(_ host: M1AudioIOHostHandle) throws -> M1AudioIOHostCounters {
        throw TestFailure.injected
    }
    func destroyHost(_ host: M1AudioIOHostHandle) {}
    func createCapture(
        aggregateDeviceID: UInt32,
        host: M1AudioIOHostHandle
    ) throws -> M1CaptureHandle { throw TestFailure.injected }
    func startCapture(_ capture: M1CaptureHandle) throws { throw TestFailure.injected }
    func stopCapture(_ capture: M1CaptureHandle) throws { throw TestFailure.injected }
    func destroyCapture(_ capture: M1CaptureHandle) throws { throw TestFailure.injected }
    func createOutput(
        deviceID: UInt32,
        sampleRate: Double,
        channelCount: Int,
        maximumFrameCount: Int,
        host: M1AudioIOHostHandle
    ) throws -> M1OutputHandle { throw TestFailure.injected }
    func startOutput(_ output: M1OutputHandle) throws { throw TestFailure.injected }
    func stopOutput(_ output: M1OutputHandle) throws { throw TestFailure.injected }
    func outputDiagnostics(_ output: M1OutputHandle) throws -> M1OutputHostDiagnostics {
        throw TestFailure.injected
    }
    func destroyOutput(_ output: M1OutputHandle) throws { throw TestFailure.injected }
}

private enum TestFailure: Error {
    case injected
}
