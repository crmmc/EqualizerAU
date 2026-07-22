import Foundation
import XCTest

final class M1AudioRouteResourceControllerTests: XCTestCase {
    func testProvisionalTapAndAggregateRequestsAndReadbacksAreStrict() async throws {
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
        XCTAssertFalse(tapRequest.isMuted)
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

    func testTapFormatReadFailureRollsBackUsingPreviouslyReadUID() async throws {
        let hal = TestHALRouteOperations()
        hal.tapDataReadFailure = true
        let controller = M1AudioRouteResourceController(operations: hal)
        let generation = M1AudioRouteGeneration(rawValue: 20)
        let output = try await controller.discoverOutput(generation: generation)

        do {
            _ = try await controller.createTap(generation: generation, output: output)
            XCTFail("tap format read failure must fail creation")
        } catch TestFailure.injected {
        }

        XCTAssertEqual(hal.destroyedTapIDs, [101])
        let pending = await controller.hasPendingResources()
        XCTAssertFalse(pending)
    }

    func testTapUIDReadAndImmediateDestroyFailureRetainsUnknownIdentityOwnership() async throws {
        let hal = TestHALRouteOperations()
        hal.tapUIDReadFailure = true
        hal.tapDestroyFailuresRemaining = 1
        let controller = M1AudioRouteResourceController(operations: hal)
        let generation = M1AudioRouteGeneration(rawValue: 21)
        let output = try await controller.discoverOutput(generation: generation)

        do {
            _ = try await controller.createTap(generation: generation, output: output)
            XCTFail("tap UID read failure must fail creation")
        } catch TestFailure.injected {
        }
        let pending = await controller.hasPendingResources()
        XCTAssertTrue(pending)
        XCTAssertEqual(hal.destroyedTapIDs, [101])

        do {
            try await controller.cleanupPendingResources()
            XCTFail("unknown identity must not be destroyed after the initial rollback window")
        } catch let error as M1AudioRouteError {
            XCTAssertEqual(error, .invalidTap("pending tap identity is unavailable"))
        }
        XCTAssertEqual(hal.destroyedTapIDs, [101])
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

    func testHandoverAllowsOnlyVerifiedOldTapAndSameOutputIdentity() async throws {
        let hal = TestHALRouteOperations()
        hal.tapObjectIDs = [101, 102]
        hal.tapDataByObjectID[102] = M1HALTapData(uid: "tap.new", format: hal.supportedFormat)
        let controller = M1AudioRouteResourceController(operations: hal)
        let firstGeneration = M1AudioRouteGeneration(rawValue: 30)
        let firstOutput = try await controller.discoverOutput(generation: firstGeneration)
        let oldTap = try await controller.createTap(
            generation: firstGeneration,
            output: firstOutput
        )
        let secondGeneration = M1AudioRouteGeneration(rawValue: 31)
        let secondOutput = try await controller.discoverOutput(generation: secondGeneration)

        let newTap = try await controller.createTap(
            generation: secondGeneration,
            output: secondOutput,
            handoverGuard: oldTap
        )

        XCTAssertEqual(newTap.descriptor.objectID, 102)
        XCTAssertEqual(newTap.descriptor.persistentUID, "tap.new")
        XCTAssertEqual(hal.tapRequests.count, 2)
        try await controller.destroyTap(oldTap)
        try await controller.destroyTap(newTap)
        XCTAssertEqual(hal.destroyOrder, ["tap:101", "tap:102"])
    }

    func testStartupPreparationUsesOwnedRouteTapWithoutCreatingSecondTap() async throws {
        let hal = TestHALRouteOperations()
        let controller = M1AudioRouteResourceController(operations: hal)
        let generation = M1AudioRouteGeneration(rawValue: 32)
        let output = try await controller.discoverOutput(generation: generation)
        let routeTap = try await controller.createTap(generation: generation, output: output)

        try await controller.prepareTapForCapture(routeTap)

        XCTAssertEqual(hal.tapRequests.count, 1)
        XCTAssertFalse(try XCTUnwrap(hal.tapRequests.first).isMuted)
        XCTAssertEqual(hal.probedAndMutedTapIDs, [routeTap.descriptor.objectID])
        XCTAssertTrue(hal.destroyedTapIDs.isEmpty)
        try await controller.destroyTap(routeTap)
    }

    func testStartupPreparationPropagatesPermissionDenialWithoutChangingRouteOwnership() async throws {
        let hal = TestHALRouteOperations()
        hal.probeAndMuteError = M1AudioRouteError.audioCapturePermissionDenied
        let controller = M1AudioRouteResourceController(operations: hal)
        let generation = M1AudioRouteGeneration(rawValue: 33)
        let output = try await controller.discoverOutput(generation: generation)
        let routeTap = try await controller.createTap(generation: generation, output: output)

        do {
            try await controller.prepareTapForCapture(routeTap)
            XCTFail("permission denial must fail startup preparation")
        } catch let error as M1AudioRouteError {
            XCTAssertEqual(error, .audioCapturePermissionDenied)
        }

        XCTAssertEqual(hal.tapRequests.count, 1)
        XCTAssertEqual(hal.probedAndMutedTapIDs, [routeTap.descriptor.objectID])
        XCTAssertTrue(hal.destroyedTapIDs.isEmpty)
        let hasPendingAfterDenial = await controller.hasPendingResources()
        XCTAssertFalse(hasPendingAfterDenial)
        try await controller.destroyTap(routeTap)
    }

    func testForegroundPermissionVerificationUsesSameOwnedRouteTap() async throws {
        let hal = TestHALRouteOperations()
        let controller = M1AudioRouteResourceController(operations: hal)
        let generation = M1AudioRouteGeneration(rawValue: 34)
        let output = try await controller.discoverOutput(generation: generation)
        let routeTap = try await controller.createTap(generation: generation, output: output)

        try await controller.prepareTapForCapture(routeTap)
        try await controller.verifyCapturePermission(using: routeTap)

        XCTAssertEqual(hal.tapRequests.count, 1)
        XCTAssertEqual(hal.probedAndMutedTapIDs, [routeTap.descriptor.objectID])
        XCTAssertEqual(hal.permissionVerifiedTapIDs, [routeTap.descriptor.objectID])
        XCTAssertTrue(hal.destroyedTapIDs.isEmpty)
        try await controller.destroyTap(routeTap)
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

    func testDestroySkipsReusedHALObjectIDsWithDifferentPersistentUIDs() async throws {
        let hal = TestHALRouteOperations()
        let controller = M1AudioRouteResourceController(operations: hal)
        let generation = M1AudioRouteGeneration(rawValue: 6)
        let output = try await controller.discoverOutput(generation: generation)
        let tap = try await controller.createTap(generation: generation, output: output)
        let aggregate = try await controller.createAggregate(
            generation: generation,
            output: output,
            tap: tap
        )
        hal.tapUIDReadback = "replacement.tap"
        hal.aggregateUIDReadback = "replacement.aggregate"

        try await controller.destroyAggregate(aggregate)
        try await controller.destroyTap(tap)

        XCTAssertTrue(hal.destroyOrder.isEmpty)
        let hasPendingResources = await controller.hasPendingResources()
        XCTAssertFalse(hasPendingResources)
    }

    func testDestroyRetainsOwnershipWhenPersistentUIDCannotBeRead() async throws {
        let hal = TestHALRouteOperations()
        let controller = M1AudioRouteResourceController(operations: hal)
        let generation = M1AudioRouteGeneration(rawValue: 7)
        let output = try await controller.discoverOutput(generation: generation)
        let tap = try await controller.createTap(generation: generation, output: output)
        hal.tapUIDReadFailure = true

        do {
            try await controller.destroyTap(tap)
            XCTFail("UID read failure must retain ownership")
        } catch TestFailure.injected {}

        hal.tapUIDReadFailure = false
        try await controller.destroyTap(tap)
        XCTAssertEqual(hal.destroyOrder, ["tap:101"])
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

    func testFormatRecoveryWaitsForTwoConsecutiveStableOutputSnapshots() async throws {
        let hal = TestHALRouteOperations()
        hal.defaultOutputs = [44_100, 48_000, 48_000].map { hal.outputData(sampleRate: $0) }
        hal.tapUIDReadFailure = true
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
            outputFormatStabilityTiming: M1OutputFormatStabilityTiming(
                maximumObservations: 3,
                delayNanoseconds: 1,
                sleep: { _ in }
            )
        )

        do {
            try await coordinator.start(
                configuration: .transparentRecovery,
                mode: .outputFormatRecovery(
                    expectedOutput: M1MonitoredOutputIdentity(
                        objectID: 42,
                        persistentUID: "device.uid"
                    )
                )
            )
            XCTFail("injected Tap identity failure must surface")
        } catch TestFailure.injected {}

        XCTAssertEqual(hal.defaultOutputReadCount, 3)
        XCTAssertEqual(hal.tapRequests.count, 1)
        XCTAssertEqual(hal.tapRequests.first?.outputDeviceUID, "device.uid")
    }

    func testFormatRecoveryRejectsOutputThatNeverStabilizesWithinBudget() async throws {
        let hal = TestHALRouteOperations()
        hal.defaultOutputs = [44_100, 48_000, 44_100].map { hal.outputData(sampleRate: $0) }
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
            outputFormatStabilityTiming: M1OutputFormatStabilityTiming(
                maximumObservations: 3,
                delayNanoseconds: 1,
                sleep: { _ in }
            )
        )

        do {
            try await coordinator.start(
                configuration: .transparentRecovery,
                mode: .outputFormatRecovery(
                    expectedOutput: M1MonitoredOutputIdentity(
                        objectID: 42,
                        persistentUID: "device.uid"
                    )
                )
            )
            XCTFail("unstable output format must fail")
        } catch let error as M1AudioRouteError {
            XCTAssertEqual(error, .invalidOutputDevice("output format did not stabilize"))
        }

        XCTAssertEqual(hal.defaultOutputReadCount, 3)
        XCTAssertTrue(hal.tapRequests.isEmpty)
    }

    func testFormatRecoveryDowngradesWhenExpectedOutputIdentityChanged() async throws {
        let hal = TestHALRouteOperations()
        hal.tapUIDReadFailure = true
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
            )
        )

        do {
            try await coordinator.start(
                configuration: .transparentRecovery,
                mode: .outputFormatRecovery(
                    expectedOutput: M1MonitoredOutputIdentity(
                        objectID: 99,
                        persistentUID: "old-device.uid"
                    )
                )
            )
            XCTFail("injected Tap identity failure must surface")
        } catch TestFailure.injected {}

        XCTAssertEqual(hal.defaultOutputReadCount, 1)
        XCTAssertEqual(hal.tapRequests.count, 1)
    }

    func testFormatRecoveryPropagatesCancellationDuringStabilityDelay() async throws {
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
            outputFormatStabilityTiming: M1OutputFormatStabilityTiming(
                maximumObservations: 6,
                delayNanoseconds: 1,
                sleep: { _ in throw CancellationError() }
            )
        )

        do {
            try await coordinator.start(
                configuration: .transparentRecovery,
                mode: .outputFormatRecovery(
                    expectedOutput: M1MonitoredOutputIdentity(
                        objectID: 42,
                        persistentUID: "device.uid"
                    )
                )
            )
            XCTFail("cancelled stability wait must fail")
        } catch is CancellationError {}

        XCTAssertEqual(hal.defaultOutputReadCount, 1)
        XCTAssertTrue(hal.tapRequests.isEmpty)
    }

    func testFormatRecoveryKeepsOldMutedTapUntilNewRouteIsRunning() async throws {
        let events = RouteEventLog()
        let hal = TestHALRouteOperations()
        hal.eventLog = events
        hal.tapObjectIDs = [101, 102]
        hal.tapDataByObjectID[102] = M1HALTapData(uid: "tap.new", format: hal.supportedFormat)
        let coordinator = makeWorkingRouteCoordinator(hal: hal, eventLog: events)
        let output = M1MonitoredOutputIdentity(objectID: 42, persistentUID: "device.uid")

        try await coordinator.start(configuration: .transparentRecovery)
        try await coordinator.stopForOutputFormatRecovery(expectedOutput: output)

        let handoverState = await coordinator.state()
        XCTAssertEqual(handoverState, .stopped)
        XCTAssertEqual(hal.destroyOrder, ["aggregate:202"])
        XCTAssertTrue(hal.destroyedTapIDs.isEmpty)

        events.events.removeAll()
        hal.defaultOutputs = [48_000, 48_000].map { hal.outputData(sampleRate: $0) }
        try await coordinator.start(
            configuration: .transparentRecovery,
            mode: .outputFormatRecovery(expectedOutput: output)
        )

        XCTAssertEqual(hal.tapRequests.count, 2)
        XCTAssertEqual(hal.destroyedTapIDs, [101])
        XCTAssertLessThan(
            try XCTUnwrap(events.events.firstIndex(of: "outputStarted")),
            try XCTUnwrap(events.events.firstIndex(of: "tapDestroyed:101"))
        )
        let runningState = await coordinator.state()
        XCTAssertEqual(runningState, .running(
            generation: M1AudioRouteGeneration(rawValue: 2),
            bridgeGeneration: 2
        ))

        try await coordinator.stop()
        XCTAssertEqual(hal.destroyedTapIDs, [101, 102])
        let stoppedState = await coordinator.state()
        XCTAssertEqual(stoppedState, .stopped)
    }

    func testFormatRecoveryGuardDestroyFailureIsRetainedForExplicitStopRetry() async throws {
        let hal = TestHALRouteOperations()
        hal.tapObjectIDs = [101, 102]
        hal.tapDataByObjectID[102] = M1HALTapData(uid: "tap.new", format: hal.supportedFormat)
        let coordinator = makeWorkingRouteCoordinator(hal: hal)
        let output = M1MonitoredOutputIdentity(objectID: 42, persistentUID: "device.uid")

        try await coordinator.start(configuration: .transparentRecovery)
        try await coordinator.stopForOutputFormatRecovery(expectedOutput: output)
        hal.tapDestroyFailuresRemaining = 1
        hal.defaultOutputs = [48_000, 48_000].map { hal.outputData(sampleRate: $0) }

        do {
            try await coordinator.start(
                configuration: .transparentRecovery,
                mode: .outputFormatRecovery(expectedOutput: output)
            )
            XCTFail("guard destroy failure must fail the replacement start")
        } catch TestFailure.injected {}

        let cleanupState = await coordinator.state()
        XCTAssertEqual(
            cleanupState,
            .cleanupRequired(generation: M1AudioRouteGeneration(rawValue: 1))
        )
        XCTAssertEqual(hal.destroyedTapIDs, [101, 102])

        try await coordinator.stop()
        XCTAssertEqual(hal.destroyedTapIDs, [101, 102, 101])
        let stoppedState = await coordinator.state()
        XCTAssertEqual(stoppedState, .stopped)
    }

    func testCancelledFormatRecoveryDestroysRetainedMuteGuard() async throws {
        let hal = TestHALRouteOperations()
        hal.tapObjectIDs = [101]
        let coordinator = makeWorkingRouteCoordinator(
            hal: hal,
            stabilityTiming: M1OutputFormatStabilityTiming(
                maximumObservations: 3,
                delayNanoseconds: 1,
                sleep: { _ in throw CancellationError() }
            )
        )
        let output = M1MonitoredOutputIdentity(objectID: 42, persistentUID: "device.uid")

        try await coordinator.start(configuration: .transparentRecovery)
        try await coordinator.stopForOutputFormatRecovery(expectedOutput: output)
        hal.defaultOutputs = [hal.outputData(sampleRate: 48_000)]

        do {
            try await coordinator.start(
                configuration: .transparentRecovery,
                mode: .outputFormatRecovery(expectedOutput: output)
            )
            XCTFail("cancelled stability wait must fail replacement start")
        } catch is CancellationError {}

        XCTAssertEqual(hal.destroyedTapIDs, [101])
        let state = await coordinator.state()
        XCTAssertEqual(state, .stopped)
    }

    func testGenerationScopedStopOwnsAndDestroysMatchingRetainedMuteGuard() async throws {
        let hal = TestHALRouteOperations()
        hal.tapObjectIDs = [101]
        let coordinator = makeWorkingRouteCoordinator(hal: hal)
        let output = M1MonitoredOutputIdentity(objectID: 42, persistentUID: "device.uid")

        try await coordinator.start(configuration: .transparentRecovery)
        try await coordinator.stopForOutputFormatRecovery(expectedOutput: output)

        let staleAccepted = try await coordinator.stop(bridgeGeneration: 999)
        XCTAssertFalse(staleAccepted)
        XCTAssertTrue(hal.destroyedTapIDs.isEmpty)

        let guardAccepted = try await coordinator.stop(bridgeGeneration: 1)
        XCTAssertTrue(guardAccepted)
        XCTAssertEqual(hal.destroyedTapIDs, [101])
        let state = await coordinator.state()
        XCTAssertEqual(state, .stopped)
    }

    func testGenerationScopedStopDoesNotReenterSpecialStopInProgress() async throws {
        let stopGate = RouteAsyncGate()
        let sleepEntered = expectation(description: "special stop reached fade wait")
        let audioOperations = TestAudioIOOperations(fadeCompletionResponses: [false, true])
        let hal = TestHALRouteOperations()
        hal.tapObjectIDs = [101]
        let coordinator = makeWorkingRouteCoordinator(
            hal: hal,
            audioOperations: audioOperations,
            audioIOTiming: M1AudioIOControlTiming(
                nowNanoseconds: { 0 },
                sleep: { _ in
                    sleepEntered.fulfill()
                    await stopGate.wait()
                }
            )
        )
        let output = M1MonitoredOutputIdentity(objectID: 42, persistentUID: "device.uid")
        try await coordinator.start(configuration: .transparentRecovery)

        let specialStop = Task {
            try await coordinator.stopForOutputFormatRecovery(expectedOutput: output)
        }
        await fulfillment(of: [sleepEntered], timeout: 1)

        let callbackAccepted = try await coordinator.stop(bridgeGeneration: 1)
        XCTAssertFalse(callbackAccepted)
        await stopGate.open()
        try await specialStop.value

        XCTAssertTrue(hal.destroyedTapIDs.isEmpty)
        try await coordinator.stop()
        XCTAssertEqual(hal.destroyedTapIDs, [101])
    }

    func testNormalStopJoinsSpecialStopAndDestroysTransferredGuard() async throws {
        let stopGate = RouteAsyncGate()
        let sleepEntered = expectation(description: "special stop reached fade wait")
        let audioOperations = TestAudioIOOperations(fadeCompletionResponses: [false, true])
        let hal = TestHALRouteOperations()
        hal.tapObjectIDs = [101]
        let coordinator = makeWorkingRouteCoordinator(
            hal: hal,
            audioOperations: audioOperations,
            audioIOTiming: M1AudioIOControlTiming(
                nowNanoseconds: { 0 },
                sleep: { _ in
                    sleepEntered.fulfill()
                    await stopGate.wait()
                }
            )
        )
        let output = M1MonitoredOutputIdentity(objectID: 42, persistentUID: "device.uid")
        try await coordinator.start(configuration: .transparentRecovery)

        let specialStop = Task {
            try await coordinator.stopForOutputFormatRecovery(expectedOutput: output)
        }
        await fulfillment(of: [sleepEntered], timeout: 1)
        let normalStop = Task { try await coordinator.stop() }
        await Task.yield()
        await stopGate.open()

        try await specialStop.value
        try await normalStop.value
        XCTAssertEqual(hal.destroyOrder, ["aggregate:202", "tap:101"])
        let state = await coordinator.state()
        XCTAssertEqual(state, .stopped)
    }

    func testIdentityChangeReleasesGuardBeforeDowngradedReplacementAttempt() async throws {
        let hal = TestHALRouteOperations()
        hal.tapObjectIDs = [101, 102]
        hal.tapDataByObjectID[102] = M1HALTapData(uid: "tap.new", format: hal.supportedFormat)
        let coordinator = makeWorkingRouteCoordinator(hal: hal)
        let oldOutput = M1MonitoredOutputIdentity(objectID: 42, persistentUID: "device.uid")

        try await coordinator.start(configuration: .transparentRecovery)
        try await coordinator.stopForOutputFormatRecovery(expectedOutput: oldOutput)
        hal.defaultOutputs = [hal.outputData(
            sampleRate: 48_000,
            objectID: 84,
            uid: "device.new"
        )]
        hal.tapUIDReadFailureObjectIDs = [102]

        do {
            try await coordinator.start(
                configuration: .transparentRecovery,
                mode: .outputFormatRecovery(expectedOutput: oldOutput)
            )
            XCTFail("injected replacement Tap read must fail")
        } catch TestFailure.injected {}

        XCTAssertEqual(hal.destroyedTapIDs, [101, 102])
        XCTAssertEqual(hal.destroyOrder.suffix(2), ["tap:101", "tap:102"])
        let state = await coordinator.state()
        XCTAssertEqual(state, .stopped)
    }

    func testStartProbesAfterCaptureRegistrationAndMutesBeforeCaptureStart() async throws {
        let events = RouteEventLog()
        let hal = TestHALRouteOperations()
        hal.eventLog = events
        let coordinator = makeWorkingRouteCoordinator(hal: hal, eventLog: events)

        try await coordinator.start(configuration: .transparentRecovery)

        XCTAssertEqual(hal.tapRequests.count, 1)
        XCTAssertFalse(try XCTUnwrap(hal.tapRequests.first).isMuted)
        XCTAssertEqual(hal.probedAndMutedTapIDs, [101])
        XCTAssertLessThan(
            try XCTUnwrap(events.events.firstIndex(of: "captureCreated")),
            try XCTUnwrap(events.events.firstIndex(of: "tapProbedAndMuted:101"))
        )
        XCTAssertLessThan(
            try XCTUnwrap(events.events.firstIndex(of: "tapProbedAndMuted:101")),
            try XCTUnwrap(events.events.firstIndex(of: "captureStarted"))
        )
        XCTAssertLessThan(
            try XCTUnwrap(events.events.firstIndex(of: "captureStarted")),
            try XCTUnwrap(events.events.firstIndex(of: "outputStarted"))
        )

        try await coordinator.stop()
    }

    func testStartupPermissionDenialNeverStartsCaptureAndCleansRoute() async throws {
        let events = RouteEventLog()
        let hal = TestHALRouteOperations()
        hal.eventLog = events
        hal.probeAndMuteError = M1AudioRouteError.audioCapturePermissionDenied
        let coordinator = makeWorkingRouteCoordinator(hal: hal, eventLog: events)

        do {
            try await coordinator.start(configuration: .transparentRecovery)
            XCTFail("permission denial must fail route start")
        } catch let error as M1AudioRouteError {
            XCTAssertEqual(error, .audioCapturePermissionDenied)
        }

        XCTAssertNotNil(events.events.firstIndex(of: "captureCreated"))
        XCTAssertNotNil(events.events.firstIndex(of: "tapProbedAndMuted:101"))
        XCTAssertNil(events.events.firstIndex(of: "captureStarted"))
        XCTAssertNil(events.events.firstIndex(of: "outputStarted"))
        XCTAssertEqual(hal.destroyOrder, ["aggregate:202", "tap:101"])
        let state = await coordinator.state()
        XCTAssertEqual(state, .stopped)
    }

    func testStartupPermissionFailureRetainsTapWhenCleanupFailsAndStopRetries() async throws {
        let hal = TestHALRouteOperations()
        hal.probeAndMuteError = M1AudioRouteError.audioCapturePermissionDenied
        hal.tapDestroyFailuresRemaining = 1
        let coordinator = makeWorkingRouteCoordinator(hal: hal)

        do {
            try await coordinator.start(configuration: .transparentRecovery)
            XCTFail("cleanup failure must replace the startup error")
        } catch TestFailure.injected {}

        XCTAssertEqual(hal.destroyedTapIDs, [101])
        XCTAssertEqual(hal.destroyOrder, ["aggregate:202"])
        let cleanupState = await coordinator.state()
        XCTAssertEqual(
            cleanupState,
            .cleanupRequired(generation: M1AudioRouteGeneration(rawValue: 1))
        )

        try await coordinator.stop()
        XCTAssertEqual(hal.destroyedTapIDs, [101, 101])
        XCTAssertEqual(hal.destroyOrder, ["aggregate:202", "tap:101"])
        let stoppedState = await coordinator.state()
        XCTAssertEqual(stoppedState, .stopped)
    }

    func testRunningCoordinatorPermissionProbeLeavesCurrentRouteRunning() async throws {
        let hal = TestHALRouteOperations()
        let coordinator = makeWorkingRouteCoordinator(hal: hal)
        try await coordinator.start(configuration: .transparentRecovery)

        let verified = try await coordinator.verifyCapturePermission()

        XCTAssertTrue(verified)
        XCTAssertEqual(hal.tapRequests.count, 1)
        XCTAssertEqual(hal.probedAndMutedTapIDs, [101])
        XCTAssertEqual(hal.permissionVerifiedTapIDs, [101])
        XCTAssertTrue(hal.destroyedTapIDs.isEmpty)
        let runningState = await coordinator.state()
        XCTAssertEqual(runningState, .running(
            generation: M1AudioRouteGeneration(rawValue: 1),
            bridgeGeneration: 1
        ))

        try await coordinator.stop()
        XCTAssertEqual(hal.destroyedTapIDs, [101])
    }

    func testRunningCoordinatorPermissionDenialPreservesRouteForProductSafetyStop() async throws {
        let hal = TestHALRouteOperations()
        let coordinator = makeWorkingRouteCoordinator(hal: hal)
        try await coordinator.start(configuration: .transparentRecovery)
        hal.permissionVerificationError = M1AudioRouteError.audioCapturePermissionDenied

        do {
            _ = try await coordinator.verifyCapturePermission()
            XCTFail("permission denial must reach the product controller")
        } catch let error as M1AudioRouteError {
            XCTAssertEqual(error, .audioCapturePermissionDenied)
        }

        let runningState = await coordinator.state()
        XCTAssertEqual(runningState, .running(
            generation: M1AudioRouteGeneration(rawValue: 1),
            bridgeGeneration: 1
        ))
        XCTAssertTrue(hal.destroyedTapIDs.isEmpty)

        try await coordinator.stop()
        XCTAssertEqual(hal.destroyedTapIDs, [101])
    }

    func testConcurrentNormalStopsJoinTheSameCleanup() async throws {
        let stopGate = RouteAsyncGate()
        let sleepEntered = expectation(description: "first stop reached fade wait")
        let audioOperations = TestAudioIOOperations(fadeCompletionResponses: [false, true])
        let hal = TestHALRouteOperations()
        hal.tapObjectIDs = [101]
        let coordinator = makeWorkingRouteCoordinator(
            hal: hal,
            audioOperations: audioOperations,
            audioIOTiming: M1AudioIOControlTiming(
                nowNanoseconds: { 0 },
                sleep: { _ in
                    sleepEntered.fulfill()
                    await stopGate.wait()
                }
            )
        )
        try await coordinator.start(configuration: .transparentRecovery)

        let firstStop = Task { try await coordinator.stop() }
        await fulfillment(of: [sleepEntered], timeout: 1)
        let secondStop = Task { try await coordinator.stop() }
        await Task.yield()
        await stopGate.open()

        try await firstStop.value
        try await secondStop.value
        XCTAssertEqual(hal.destroyOrder, ["aggregate:202", "tap:101"])
        let state = await coordinator.state()
        XCTAssertEqual(state, .stopped)
    }

    private func makeWorkingRouteCoordinator(
        hal: TestHALRouteOperations,
        eventLog: RouteEventLog? = nil,
        audioOperations: TestAudioIOOperations? = nil,
        audioIOTiming: M1AudioIOControlTiming? = nil,
        stabilityTiming: M1OutputFormatStabilityTiming = M1OutputFormatStabilityTiming(
            maximumObservations: 3,
            delayNanoseconds: 1,
            sleep: { _ in }
        )
    ) -> M1NativeAudioRouteCoordinator {
        let runtimeAccess = M1RuntimeLeaseAccess(stopHandler: { _, _ in })
        return M1NativeAudioRouteCoordinator(
            routeResources: M1AudioRouteResourceController(operations: hal),
            audioIO: M1AudioIOController(
                operations: audioOperations ?? TestAudioIOOperations(eventLog: eventLog),
                timing: audioIOTiming
                    ?? M1AudioIOControlTiming(nowNanoseconds: { 0 }, sleep: { _ in })
            ),
            runtimeFactory: RealTestRuntimeFactory(),
            runtimeAccess: runtimeAccess,
            retirementMaintenance: M1RetirementMaintenanceCoordinator(
                access: runtimeAccess,
                timing: M1RetirementMaintenanceTiming(nowNanoseconds: { 0 }, sleep: { _ in })
            ),
            outputFormatStabilityTiming: stabilityTiming
        )
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
    var defaultOutputs: [M1HALOutputDeviceData] = []
    var tapUIDReadback: String?
    var aggregateUIDReadback: String?
    var tapUIDReadFailure = false
    var tapDataReadFailure = false
    var tapObjectIDs: [UInt32] = []
    var tapDataByObjectID: [UInt32: M1HALTapData] = [:]
    var tapUIDReadFailureObjectIDs: Set<UInt32> = []
    var probedAndMutedTapIDs: [UInt32] = []
    var permissionVerifiedTapIDs: [UInt32] = []
    var probeAndMuteError: (any Error)?
    var permissionVerificationError: (any Error)?
    var eventLog: RouteEventLog?

    init() {
        tapData = M1HALTapData(uid: "tap.uid", format: supportedFormat)
    }

    func readDefaultOutputDevice() throws -> M1HALOutputDeviceData {
        defaultOutputReadCount += 1
        if let defaultOutputError { throw defaultOutputError }
        if !defaultOutputs.isEmpty {
            return defaultOutputs.removeFirst()
        }
        return outputData(sampleRate: 48_000)
    }

    func outputData(
        sampleRate: Double,
        objectID: UInt32 = 42,
        uid: String = "device.uid"
    ) -> M1HALOutputDeviceData {
        M1HALOutputDeviceData(
            objectID: objectID,
            uid: uid,
            name: "Output",
            isAlive: true,
            sampleRate: sampleRate,
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
        let objectID = tapObjectIDs.isEmpty ? 101 : tapObjectIDs.removeFirst()
        eventLog?.events.append("tapCreated:\(objectID)")
        return objectID
    }

    func probeAndMuteProcessTap(_ objectID: UInt32) throws {
        probedAndMutedTapIDs.append(objectID)
        eventLog?.events.append("tapProbedAndMuted:\(objectID)")
        if let probeAndMuteError { throw probeAndMuteError }
    }

    func verifyProcessTapCapturePermission(_ objectID: UInt32) throws {
        permissionVerifiedTapIDs.append(objectID)
        eventLog?.events.append("tapPermissionVerified:\(objectID)")
        if let permissionVerificationError { throw permissionVerificationError }
    }

    func readProcessTap(_ objectID: UInt32) throws -> M1HALTapData {
        if tapDataReadFailure { throw TestFailure.injected }
        return tapDataByObjectID[objectID] ?? tapData
    }

    func readProcessTapUID(_ objectID: UInt32) throws -> String {
        if tapUIDReadFailure || tapUIDReadFailureObjectIDs.contains(objectID) {
            throw TestFailure.injected
        }
        return tapUIDReadback ?? tapDataByObjectID[objectID]?.uid ?? tapData.uid
    }

    func destroyProcessTap(_ objectID: UInt32) throws {
        destroyedTapIDs.append(objectID)
        if tapDestroyFailuresRemaining > 0 {
            tapDestroyFailuresRemaining -= 1
            throw TestFailure.injected
        }
        destroyOrder.append("tap:\(objectID)")
        eventLog?.events.append("tapDestroyed:\(objectID)")
    }

    func createAggregateDevice(_ request: M1AggregateRequest) throws -> UInt32 {
        aggregateRequests.append(request)
        eventLog?.events.append("aggregateCreated:202")
        return 202
    }

    func readAggregateDevice(_ objectID: UInt32) throws -> M1HALAggregateData {
        M1HALAggregateData(
            uid: aggregateRequests.last!.uid,
            tapUIDs: [aggregateRequests.last!.tapUID],
            format: supportedFormat,
            maximumFrameCount: 256,
            bufferChannelCounts: [2]
        )
    }

    func readAggregateDeviceUID(_ objectID: UInt32) throws -> String {
        aggregateUIDReadback ?? aggregateRequests.last!.uid
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

private struct RealTestRuntimeFactory: M1RuntimeCreating, @unchecked Sendable {
    func createRuntime(
        bridgeGeneration: UInt64,
        initialState: M1RuntimeInitialState,
        maximumFrameCount: Int,
        sampleRate: Double
    ) throws -> M1RuntimeHandleLease {
        let channelCount = initialState.stagesByChannel.count
        guard let channels = UInt32(exactly: channelCount), channels > 0,
              let maximumFrames = UInt32(exactly: maximumFrameCount), maximumFrames > 0
        else {
            throw M1AudioIOError.invalidConfiguration("invalid test Runtime dimensions")
        }
        let channelCounts = [channels]
        var prepared: OpaquePointer? = try M1RuntimePreparedStateFactory.create(
            stagesByChannel: initialState.stagesByChannel
        )
        var runtime: OpaquePointer?
        let status = channelCounts.withUnsafeBufferPointer { counts in
            var description = EAUM1RuntimeDescription(
                sampleRate: sampleRate,
                maximumFrameCount: maximumFrames,
                bufferCount: UInt32(channelCounts.count),
                channelCounts: counts.baseAddress,
                effectsEnabled: initialState.effectsEnabled ? 1 : 0
            )
            return EAUM1RuntimeCreate(&description, &prepared, &runtime)
        }
        if status != EAUM1StatusOK {
            EAUM1PreparedStateDestroy(prepared)
        }
        guard status == EAUM1StatusOK, prepared == nil, let runtime else {
            throw M1AudioIOError.invalidConfiguration("test Runtime creation failed: \(status)")
        }
        return M1RuntimeHandleLease(bridgeGeneration: bridgeGeneration, pointer: runtime)
    }

    func destroyRuntime(_ runtime: M1RuntimeHandleLease) {
        EAUM1RuntimeDestroy(runtime.pointer)
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

private final class TestAudioIOOperations: M1AudioIOOperations, @unchecked Sendable {
    private struct OutputDescription {
        let deviceID: UInt32
        let sampleRate: Double
        let channelCount: Int
        let maximumFrameCount: Int
    }

    private var outputs: [UUID: OutputDescription] = [:]
    private var runningOutputs: Set<UUID> = []
    private let eventLog: RouteEventLog?
    private var fadeCompletionResponses: [Bool]

    init(
        eventLog: RouteEventLog? = nil,
        fadeCompletionResponses: [Bool] = []
    ) {
        self.eventLog = eventLog
        self.fadeCompletionResponses = fadeCompletionResponses
    }

    func createHost(
        configuration: M1AudioIOHostConfiguration,
        runtime: M1RuntimeHandleLease
    ) throws -> M1AudioIOHostHandle {
        M1AudioIOHostHandle()
    }

    func beginStopping(_ host: M1AudioIOHostHandle) {}
    func requestFadeOut(_ host: M1AudioIOHostHandle, frameCount: Int) {}
    func isFadeComplete(_ host: M1AudioIOHostHandle) -> Bool {
        fadeCompletionResponses.isEmpty ? true : fadeCompletionResponses.removeFirst()
    }
    func isQuiescent(_ host: M1AudioIOHostHandle) -> Bool { true }
    func hostDiagnostics(_ host: M1AudioIOHostHandle) throws -> M1AudioIOHostCounters {
        M1AudioIOHostCounters(
            capturedFrames: 0,
            renderedFrames: 0,
            overflowedBlocks: 0,
            underrunBlocks: 0,
            droppedBacklogFrames: 0,
            invalidCallbacks: 0,
            overlappingRenderCallbacks: 0
        )
    }
    func destroyHost(_ host: M1AudioIOHostHandle) {}
    func createCapture(
        aggregateDeviceID: UInt32,
        host: M1AudioIOHostHandle
    ) throws -> M1CaptureHandle {
        eventLog?.events.append("captureCreated")
        return M1CaptureHandle()
    }
    func startCapture(_ capture: M1CaptureHandle) throws {
        eventLog?.events.append("captureStarted")
    }
    func stopCapture(_ capture: M1CaptureHandle) throws {}
    func destroyCapture(_ capture: M1CaptureHandle) throws {}

    func createOutput(
        deviceID: UInt32,
        sampleRate: Double,
        channelCount: Int,
        maximumFrameCount: Int,
        host: M1AudioIOHostHandle
    ) throws -> M1OutputHandle {
        let output = M1OutputHandle()
        outputs[output.identity] = OutputDescription(
            deviceID: deviceID,
            sampleRate: sampleRate,
            channelCount: channelCount,
            maximumFrameCount: maximumFrameCount
        )
        return output
    }

    func startOutput(_ output: M1OutputHandle) throws {
        runningOutputs.insert(output.identity)
        eventLog?.events.append("outputStarted")
    }

    func stopOutput(_ output: M1OutputHandle) throws {
        runningOutputs.remove(output.identity)
    }

    func outputDiagnostics(_ output: M1OutputHandle) throws -> M1OutputHostDiagnostics {
        let value = outputs[output.identity]!
        return M1OutputHostDiagnostics(
            currentDeviceID: value.deviceID,
            currentDeviceUID: "device.uid",
            deviceSampleRate: value.sampleRate,
            deviceChannelCount: value.channelCount,
            deviceFormatSupported: true,
            clientSampleRate: value.sampleRate,
            clientChannelCount: value.channelCount,
            clientFormatSupported: true,
            maximumFrameCount: value.maximumFrameCount,
            isRunning: runningOutputs.contains(output.identity)
        )
    }

    func destroyOutput(_ output: M1OutputHandle) throws {
        runningOutputs.remove(output.identity)
        outputs.removeValue(forKey: output.identity)
    }
}

private final class RouteEventLog: @unchecked Sendable {
    var events: [String] = []
}

private actor RouteAsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}

private enum TestFailure: Error {
    case injected
}
