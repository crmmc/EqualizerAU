import Foundation
import XCTest

final class M1AudioRouteResourceControllerTests: XCTestCase {
    func testPassiveOutputLayoutDiscoveryDoesNotCreateRouteResources() async {
        let hal = TestHALRouteOperations()
        let coordinator = makeWorkingRouteCoordinator(hal: hal)

        let layout = await coordinator.discoverOutputLayout()
        let state = await coordinator.state()

        XCTAssertEqual(layout?.channels.map(\.identifier.rawValue), ["L", "R"])
        XCTAssertTrue(hal.tapRequests.isEmpty)
        XCTAssertTrue(hal.aggregateRequests.isEmpty)
        XCTAssertEqual(state, .stopped)
    }

    func testOutputDiscoveryRejectsMissingPersistentIdentity() async {
        let hal = TestHALRouteOperations()
        hal.defaultOutputs = [hal.outputData(sampleRate: 48_000, uid: "")]
        let controller = M1AudioRouteResourceController(operations: hal)

        do {
            _ = try await controller.discoverOutput(generation: .init(rawValue: 1))
            XCTFail("missing output UID must fail")
        } catch let error as M1AudioRouteError {
            XCTAssertEqual(error, .invalidOutputDevice("missing UID or device is not alive"))
        } catch {
            XCTFail("unexpected output discovery error: \(error)")
        }
    }

    func testPassiveDiscoveryFailureReturnsNoLayoutWithoutCreatingResources() async {
        let hal = TestHALRouteOperations()
        hal.defaultOutputError = .noOutputDevice
        let coordinator = makeWorkingRouteCoordinator(hal: hal)

        let layout = await coordinator.discoverOutputLayout()

        XCTAssertNil(layout)
        XCTAssertTrue(hal.tapRequests.isEmpty)
        XCTAssertTrue(hal.aggregateRequests.isEmpty)
    }

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
    func testReusedTapValidationRollbackInvalidatesDestroyedHandoverGuard() async throws {
        let hal = TestHALRouteOperations()
        hal.tapObjectIDs = [101, 101, 102]
        let controller = M1AudioRouteResourceController(operations: hal)
        let firstGeneration = M1AudioRouteGeneration(rawValue: 1)
        let firstOutput = try await controller.discoverOutput(generation: firstGeneration)
        let handoverGuard = try await controller.createTap(
            generation: firstGeneration,
            output: firstOutput
        )

        let secondGeneration = M1AudioRouteGeneration(rawValue: 2)
        let secondOutput = try await controller.discoverOutput(generation: secondGeneration)
        hal.tapDataByObjectID[101] = M1HALTapData(uid: "", format: hal.supportedFormat)
        hal.tapDestroyFailuresRemaining = 1
        do {
            _ = try await controller.createTap(
                generation: secondGeneration,
                output: secondOutput,
                handoverGuard: handoverGuard
            )
            XCTFail("invalid replacement tap must fail")
        } catch let error as M1AudioRouteError {
            XCTAssertEqual(error, .invalidTap("unsupported tap UID or format"))
        }

        try await controller.cleanupPendingResources()
        let guardIsOwned = await controller.ownsTap(handoverGuard)
        XCTAssertFalse(guardIsOwned)
        try await controller.destroyTap(handoverGuard)
        hal.tapDataByObjectID[102] = M1HALTapData(uid: "tap.retry", format: hal.supportedFormat)
        let replacement = try await controller.createTap(
            generation: secondGeneration,
            output: secondOutput
        )
        try await controller.destroyTap(replacement)
        XCTAssertEqual(hal.destroyedTapIDs, [101, 101, 102])
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

    func testAggregateValidationRollbackFailureIsRetainedAndCleanupRetries() async throws {
        let hal = TestHALRouteOperations()
        hal.aggregateDataOverride = M1HALAggregateData(
            uid: "wrong.aggregate",
            tapUIDs: ["tap.uid"],
            format: hal.supportedFormat,
            maximumFrameCount: 256,
            bufferChannelCounts: [2]
        )
        hal.aggregateDestroyFailuresRemaining = 1
        let controller = M1AudioRouteResourceController(operations: hal)
        let generation = M1AudioRouteGeneration(rawValue: 41)
        let output = try await controller.discoverOutput(generation: generation)
        let tap = try await controller.createTap(generation: generation, output: output)

        do {
            _ = try await controller.createAggregate(
                generation: generation,
                output: output,
                tap: tap
            )
            XCTFail("invalid aggregate readback must fail")
        } catch let error as M1AudioRouteError {
            XCTAssertEqual(
                error,
                .invalidAggregate("aggregate identity, tap list or format mismatch")
            )
        }
        let pendingAfterFailure = await controller.hasPendingResources()
        XCTAssertTrue(pendingAfterFailure)
        hal.aggregateDataOverride = nil
        try await controller.cleanupPendingResources()
        let pendingAfterCleanup = await controller.hasPendingResources()
        XCTAssertFalse(pendingAfterCleanup)
        try await controller.destroyTap(tap)
        XCTAssertEqual(hal.aggregateDestroyAttempts, [202, 202])
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

    func testDestroyRejectsWrongKindResourcesWithoutDroppingOwnership() async throws {
        let hal = TestHALRouteOperations()
        let controller = M1AudioRouteResourceController(operations: hal)
        let generation = M1AudioRouteGeneration(rawValue: 42)
        let output = try await controller.discoverOutput(generation: generation)
        let tap = try await controller.createTap(generation: generation, output: output)
        let wrongKind = M1ProcessTapResource(
            descriptor: .init(
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
            try await controller.destroyTap(wrongKind)
            XCTFail("wrong-kind destroy must fail")
        } catch let error as M1AudioRouteError {
            XCTAssertEqual(error, .staleResource)
        }
        try await controller.destroyTap(tap)
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

    func testComputationalBypassDisablesAndFreshlyActivatesWithoutRouteRebuild() async throws {
        let hal = TestHALRouteOperations()
        let audioIO = TestAudioIOOperations()
        let runtimeAccess = M1RuntimeLeaseAccess(stopHandler: { _, _ in })
        let maintenance = M1RetirementMaintenanceCoordinator(
            access: runtimeAccess,
            timing: M1RetirementMaintenanceTiming(
                nowNanoseconds: { DispatchTime.now().uptimeNanoseconds },
                sleep: { try await Task.sleep(nanoseconds: $0) }
            )
        )
        let coordinator = M1NativeAudioRouteCoordinator(
            routeResources: M1AudioRouteResourceController(operations: hal),
            audioIO: M1AudioIOController(
                operations: audioIO,
                timing: M1AudioIOControlTiming(nowNanoseconds: { 0 }, sleep: { _ in })
            ),
            runtimeFactory: RealTestRuntimeFactory(),
            runtimeAccess: runtimeAccess,
            retirementMaintenance: maintenance
        )
        let original = M1ConfigurationSnapshot(
            effectsEnabled: true,
            nodes: [M1ProcessingNode(id: UUID(), isEnabled: true, gainDB: 6, channels: .all)]
        )
        try await coordinator.start(configuration: original)
        let runtime = try XCTUnwrap(audioIO.runtime)
        let routeCounts = (hal.tapRequests.count, hal.aggregateRequests.count)

        let disable = Task { try await coordinator.setEffectsEnabled(false) }
        for _ in 0..<100 {
            XCTAssertEqual(Int(processRuntime(runtime.pointer)), EAUM1StatusOK)
            if try await runtimeAccess.effectsState(
                bridgeGeneration: runtime.bridgeGeneration
            ) == .bypassed { break }
            try await Task.sleep(nanoseconds: 100_000)
        }
        try await disable.value
        let bypassed = try await runtimeAccess.effectsState(
            bridgeGeneration: runtime.bridgeGeneration
        )
        XCTAssertEqual(bypassed, .bypassed)

        let replacement = M1ConfigurationSnapshot(
            effectsEnabled: true,
            nodes: [M1ProcessingNode(id: UUID(), isEnabled: true, gainDB: -6, channels: .all)]
        )
        let preparation = try await coordinator.prepare(configuration: replacement)
        let activate = Task {
            try await coordinator.activateEffects(
                preparation: preparation,
                activationToken: M1EffectsActivationToken()
            )
        }
        for _ in 0..<100 {
            XCTAssertEqual(Int(processRuntime(runtime.pointer)), EAUM1StatusOK)
            if try await runtimeAccess.effectsState(
                bridgeGeneration: runtime.bridgeGeneration
            ) == .active { break }
            try await Task.sleep(nanoseconds: 100_000)
        }
        _ = try await activate.value
        let active = try await runtimeAccess.effectsState(
            bridgeGeneration: runtime.bridgeGeneration
        )
        XCTAssertEqual(active, .active)
        XCTAssertEqual(hal.tapRequests.count, routeCounts.0)
        XCTAssertEqual(hal.aggregateRequests.count, routeCounts.1)
        XCTAssertTrue(hal.destroyOrder.isEmpty)
        try await coordinator.stop()
    }

    func testCancelledActivationCompensatesBackToBypassed() async throws {
        let hal = TestHALRouteOperations()
        let audioIO = TestAudioIOOperations()
        let runtimeAccess = M1RuntimeLeaseAccess(stopHandler: { _, _ in })
        let coordinator = M1NativeAudioRouteCoordinator(
            routeResources: M1AudioRouteResourceController(operations: hal),
            audioIO: M1AudioIOController(
                operations: audioIO,
                timing: M1AudioIOControlTiming(nowNanoseconds: { 0 }, sleep: { _ in })
            ),
            runtimeFactory: RealTestRuntimeFactory(),
            runtimeAccess: runtimeAccess,
            retirementMaintenance: M1RetirementMaintenanceCoordinator(
                access: runtimeAccess,
                timing: M1RetirementMaintenanceTiming(
                    nowNanoseconds: { DispatchTime.now().uptimeNanoseconds },
                    sleep: { try await Task.sleep(nanoseconds: $0) }
                )
            )
        )
        let bypassed = M1ConfigurationSnapshot(
            effectsEnabled: false,
            nodes: [M1ProcessingNode(id: UUID(), isEnabled: true, gainDB: 6, channels: .all)]
        )
        try await coordinator.start(configuration: bypassed)
        let runtime = try XCTUnwrap(audioIO.runtime)
        let preparation = try await coordinator.prepare(configuration: M1ConfigurationSnapshot(
            effectsEnabled: true,
            nodes: [M1ProcessingNode(id: UUID(), isEnabled: true, gainDB: -6, channels: .all)]
        ))
        let activation = Task {
            try await coordinator.activateEffects(
                preparation: preparation,
                activationToken: M1EffectsActivationToken()
            )
        }

        for _ in 0..<100 {
            XCTAssertEqual(Int(processRuntime(runtime.pointer)), EAUM1StatusOK)
            if try await runtimeAccess.effectsState(
                bridgeGeneration: runtime.bridgeGeneration
            ) == .fadingIn { break }
            try await Task.sleep(nanoseconds: 100_000)
        }
        activation.cancel()
        for _ in 0..<100 {
            XCTAssertEqual(Int(processRuntime(runtime.pointer)), EAUM1StatusOK)
            if try await runtimeAccess.effectsState(
                bridgeGeneration: runtime.bridgeGeneration
            ) == .bypassed { break }
            try await Task.sleep(nanoseconds: 100_000)
        }
        do {
            _ = try await activation.value
            XCTFail("cancelled activation must not report success")
        } catch is CancellationError {}
        let state = try await runtimeAccess.effectsState(
            bridgeGeneration: runtime.bridgeGeneration
        )
        XCTAssertEqual(state, .bypassed)
        try await coordinator.stop()
    }

    func testActivationInvalidatedAtDesiredWriteBoundaryStaysBypassed() async throws {
        let hal = TestHALRouteOperations()
        let audioIO = TestAudioIOOperations()
        let token = M1EffectsActivationToken()
        let clock = InvalidatingEffectsClock(token: token, invalidationCall: 3)
        let runtimeAccess = M1RuntimeLeaseAccess(stopHandler: { _, _ in })
        let coordinator = M1NativeAudioRouteCoordinator(
            routeResources: M1AudioRouteResourceController(operations: hal),
            audioIO: M1AudioIOController(
                operations: audioIO,
                timing: M1AudioIOControlTiming(nowNanoseconds: { 0 }, sleep: { _ in })
            ),
            runtimeFactory: RealTestRuntimeFactory(),
            runtimeAccess: runtimeAccess,
            retirementMaintenance: M1RetirementMaintenanceCoordinator(
                access: runtimeAccess,
                timing: M1RetirementMaintenanceTiming(nowNanoseconds: { 0 }, sleep: { _ in })
            ),
            effectsTransitionTiming: M1EffectsTransitionTiming(
                pollInterval: 1,
                deadline: 3,
                nowNanoseconds: { await clock.now() },
                sleep: { _ in }
            )
        )
        try await coordinator.start(configuration: M1ConfigurationSnapshot(
            effectsEnabled: false,
            nodes: []
        ))
        let preparation = try await coordinator.prepare(configuration: .transparentRecovery)

        do {
            _ = try await coordinator.activateEffects(
                preparation: preparation,
                activationToken: token
            )
            XCTFail("invalidated activation must not write desired=true")
        } catch is CancellationError {}
        let runtime = try XCTUnwrap(audioIO.runtime)
        let state = try await runtimeAccess.effectsState(
            bridgeGeneration: runtime.bridgeGeneration
        )
        XCTAssertEqual(state, .bypassed)
        try await coordinator.stop()
    }

    func testColdReplaceThatReturnsAfterDeadlineDoesNotEnableEffects() async throws {
        let hal = TestHALRouteOperations()
        let audioIO = TestAudioIOOperations()
        let clock = SequencedEffectsClock(values: [0, 3])
        let runtimeAccess = M1RuntimeLeaseAccess(stopHandler: { _, _ in })
        let coordinator = M1NativeAudioRouteCoordinator(
            routeResources: M1AudioRouteResourceController(operations: hal),
            audioIO: M1AudioIOController(
                operations: audioIO,
                timing: M1AudioIOControlTiming(nowNanoseconds: { 0 }, sleep: { _ in })
            ),
            runtimeFactory: RealTestRuntimeFactory(),
            runtimeAccess: runtimeAccess,
            retirementMaintenance: M1RetirementMaintenanceCoordinator(
                access: runtimeAccess,
                timing: M1RetirementMaintenanceTiming(
                    nowNanoseconds: { 0 },
                    sleep: { _ in }
                )
            ),
            effectsTransitionTiming: M1EffectsTransitionTiming(
                pollInterval: 1,
                deadline: 3,
                nowNanoseconds: { await clock.now() },
                sleep: { _ in }
            )
        )
        try await coordinator.start(configuration: M1ConfigurationSnapshot(
            effectsEnabled: false,
            nodes: []
        ))
        let preparation = try await coordinator.prepare(configuration: .transparentRecovery)

        do {
            _ = try await coordinator.activateEffects(
                preparation: preparation,
                activationToken: M1EffectsActivationToken()
            )
            XCTFail("expired cold replacement must not enable effects")
        } catch let error as M1AudioIOError {
            XCTAssertEqual(error, .invalidState("bypassed replacement timed out"))
        }
        let runtime = try XCTUnwrap(audioIO.runtime)
        let state = try await runtimeAccess.effectsState(
            bridgeGeneration: runtime.bridgeGeneration
        )
        XCTAssertEqual(state, .bypassed)
        try await coordinator.stop()
    }

    func testActivationAckTimeoutCompensatesWithoutRecoverableStop() async throws {
        let hal = TestHALRouteOperations()
        let audioIO = TestAudioIOOperations()
        let clock = EffectsTestClock()
        let recorder = RetirementStopRecorder()
        let runtimeAccess = M1RuntimeLeaseAccess { reason, generation in
            await recorder.record(reason: reason, generation: generation)
        }
        let coordinator = M1NativeAudioRouteCoordinator(
            routeResources: M1AudioRouteResourceController(operations: hal),
            audioIO: M1AudioIOController(
                operations: audioIO,
                timing: M1AudioIOControlTiming(nowNanoseconds: { 0 }, sleep: { _ in })
            ),
            runtimeFactory: RealTestRuntimeFactory(),
            runtimeAccess: runtimeAccess,
            retirementMaintenance: M1RetirementMaintenanceCoordinator(
                access: runtimeAccess,
                timing: M1RetirementMaintenanceTiming(
                    nowNanoseconds: { await clock.now() },
                    sleep: { await clock.advance(by: $0) }
                )
            ),
            effectsTransitionTiming: M1EffectsTransitionTiming(
                pollInterval: 1,
                deadline: 3,
                nowNanoseconds: { await clock.now() },
                sleep: { await clock.advance(by: $0) }
            )
        )
        try await coordinator.start(configuration: M1ConfigurationSnapshot(
            effectsEnabled: false,
            nodes: []
        ))
        let preparation = try await coordinator.prepare(configuration: .transparentRecovery)

        do {
            _ = try await coordinator.activateEffects(
                preparation: preparation,
                activationToken: M1EffectsActivationToken()
            )
            XCTFail("missing fade-in acknowledgement must fail")
        } catch let error as M1AudioIOError {
            XCTAssertEqual(error, .invalidState("effects activation timed out"))
        }
        let runtime = try XCTUnwrap(audioIO.runtime)
        let state = try await runtimeAccess.effectsState(
            bridgeGeneration: runtime.bridgeGeneration
        )
        let stopEvents = await recorder.events()
        XCTAssertEqual(state, .bypassed)
        XCTAssertTrue(stopEvents.isEmpty)
        try await coordinator.stop()
    }

    func testComputationalBypassTimeoutRequestsRecoverableStop() async throws {
        let hal = TestHALRouteOperations()
        let audioIO = TestAudioIOOperations()
        let clock = EffectsTestClock()
        let recorder = RetirementStopRecorder()
        let runtimeAccess = M1RuntimeLeaseAccess { reason, generation in
            await recorder.record(reason: reason, generation: generation)
        }
        let coordinator = M1NativeAudioRouteCoordinator(
            routeResources: M1AudioRouteResourceController(operations: hal),
            audioIO: M1AudioIOController(
                operations: audioIO,
                timing: M1AudioIOControlTiming(nowNanoseconds: { 0 }, sleep: { _ in })
            ),
            runtimeFactory: RealTestRuntimeFactory(),
            runtimeAccess: runtimeAccess,
            retirementMaintenance: M1RetirementMaintenanceCoordinator(
                access: runtimeAccess,
                timing: M1RetirementMaintenanceTiming(
                    nowNanoseconds: { await clock.now() },
                    sleep: { await clock.advance(by: $0) }
                )
            ),
            effectsTransitionTiming: M1EffectsTransitionTiming(
                pollInterval: 1,
                deadline: 3,
                nowNanoseconds: { await clock.now() },
                sleep: { await clock.advance(by: $0) }
            )
        )
        try await coordinator.start(configuration: .transparentRecovery)

        do {
            try await coordinator.setEffectsEnabled(false)
            XCTFail("missing callback acknowledgement must time out")
        } catch let error as M1AudioIOError {
            XCTAssertEqual(error, .invalidState("effects bypass timed out"))
        }
        let events = await recorder.events()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.reason, .effectsBypassTimedOut)
        XCTAssertEqual(events.first?.generation, audioIO.runtime?.bridgeGeneration)
        try await coordinator.stop()
    }

    func testPrepareBypassesMissingIRAfterOutputDiscovery() async throws {
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
        let ir = M1ConvolutionIRReference(sourcePath: "/missing/ir.wav")
        let node = M1ProcessingNode.convolution(ir: ir)
        let configuration = M1ConfigurationSnapshot(effectsEnabled: true, nodes: [node])

        let preparation = try await coordinator.prepare(configuration: configuration)
        XCTAssertNotNil(preparation.layout)
        XCTAssertEqual(preparation.compiled?.stagesByChannel, [[], []])
        XCTAssertEqual(
            preparation.compiled?.diagnostics.convolutionBypasses,
            [
                M1ConvolutionBypassDiagnostic(
                    nodeID: node.id,
                    source: ir,
                    reason: .resource(.missingResource)
                ),
            ]
        )
        XCTAssertEqual(hal.defaultOutputReadCount, 1)
    }

    func testPrepareDefersIRLoadingAndCapacityUntilOutputIsAvailable() async throws {
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
        let ir = M1ConvolutionIRReference(sourcePath: "/missing/shared.wav")

        let waiting = try await coordinator.prepare(configuration: M1ConfigurationSnapshot(
            effectsEnabled: true,
            nodes: (0...M1ProcessingBuilder.maximumConvolutionStages).map { _ in .convolution(ir: ir) }
        ))
        XCTAssertEqual(waiting, .waitingForOutput)
        XCTAssertEqual(loader.validationCount, 0)
    }

    func testStopCancelsAndJoinsInFlightStartCompilation() async throws {
        let entered = expectation(description: "start IR compile entered")
        let loader = CompileCancellationObservingIRLoader { entered.fulfill() }
        let runtimeAccess = M1RuntimeLeaseAccess(stopHandler: { _, _ in })
        let coordinator = M1NativeAudioRouteCoordinator(
            routeResources: M1AudioRouteResourceController(operations: TestHALRouteOperations()),
            audioIO: M1AudioIOController(
                operations: TestAudioIOOperations(),
                timing: M1AudioIOControlTiming(nowNanoseconds: { 0 }, sleep: { _ in })
            ),
            runtimeFactory: RealTestRuntimeFactory(),
            runtimeAccess: runtimeAccess,
            retirementMaintenance: M1RetirementMaintenanceCoordinator(
                access: runtimeAccess,
                timing: M1RetirementMaintenanceTiming(nowNanoseconds: { 0 }, sleep: { _ in })
            ),
            irLoader: loader
        )
        let start = Task {
            try await coordinator.start(configuration: M1ConfigurationSnapshot(
                effectsEnabled: true,
                nodes: [.convolution(ir: .init(sourcePath: "/tmp/cancel-start.wav"))]
            ))
        }

        await fulfillment(of: [entered], timeout: 1)
        start.cancel()
        let stop = Task { try await coordinator.stop() }
        do {
            try await start.value
            XCTFail("cancelled start must fail")
        } catch is CancellationError {}
        try await stop.value
        let state = await coordinator.state()
        XCTAssertEqual(state, .stopped)
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
        let ir = M1ConvolutionIRReference(sourcePath: "/tmp/cancel-compile.wav")
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
    func testFormatRecoveryAdoptsReusedTapObjectIDWithoutLeakingNewTap() async throws {
        let hal = TestHALRouteOperations()
        hal.tapObjectIDs = [101, 101]
        let coordinator = makeWorkingRouteCoordinator(hal: hal)
        let output = M1MonitoredOutputIdentity(objectID: 42, persistentUID: "device.uid")

        try await coordinator.start(configuration: .transparentRecovery)
        try await coordinator.stopForOutputFormatRecovery(expectedOutput: output)

        hal.tapDataByObjectID[101] = M1HALTapData(uid: "tap.reused", format: hal.supportedFormat)
        hal.defaultOutputs = [48_000, 48_000].map { hal.outputData(sampleRate: $0) }
        try await coordinator.start(
            configuration: .transparentRecovery,
            mode: .outputFormatRecovery(expectedOutput: output)
        )

        let runningState = await coordinator.state()
        XCTAssertEqual(
            runningState,
            .running(generation: M1AudioRouteGeneration(rawValue: 2), bridgeGeneration: 2)
        )
        XCTAssertTrue(hal.destroyedTapIDs.isEmpty)

        try await coordinator.stop()
        XCTAssertEqual(hal.destroyedTapIDs, [101])
        let stoppedState = await coordinator.state()
        XCTAssertEqual(stoppedState, .stopped)
    }
    func testFormatRecoveryRetryUsesReplacementTapAfterReusedObjectIDStartFailure() async throws {
        let hal = TestHALRouteOperations()
        hal.tapObjectIDs = [101, 101, 102]
        let coordinator = makeWorkingRouteCoordinator(hal: hal)
        let output = M1MonitoredOutputIdentity(objectID: 42, persistentUID: "device.uid")

        try await coordinator.start(configuration: .transparentRecovery)
        try await coordinator.stopForOutputFormatRecovery(expectedOutput: output)
        hal.tapDataByObjectID[101] = M1HALTapData(uid: "tap.reused", format: hal.supportedFormat)
        hal.defaultOutputs = [48_000, 48_000].map { hal.outputData(sampleRate: $0) }
        hal.probeAndMuteError = TestFailure.injected

        do {
            try await coordinator.start(
                configuration: .transparentRecovery,
                mode: .outputFormatRecovery(expectedOutput: output)
            )
            XCTFail("injected post-handover failure must fail the first recovery attempt")
        } catch TestFailure.injected {}

        hal.probeAndMuteError = nil
        hal.tapDataByObjectID[102] = M1HALTapData(uid: "tap.retry", format: hal.supportedFormat)
        hal.defaultOutputs = [48_000, 48_000].map { hal.outputData(sampleRate: $0) }
        try await coordinator.start(
            configuration: .transparentRecovery,
            mode: .outputFormatRecovery(expectedOutput: output)
        )

        let runningState = await coordinator.state()
        XCTAssertEqual(
            runningState,
            .running(generation: M1AudioRouteGeneration(rawValue: 3), bridgeGeneration: 3)
        )
        XCTAssertEqual(hal.destroyedTapIDs, [101])
        try await coordinator.stop()
        XCTAssertEqual(hal.destroyedTapIDs, [101, 102])
    }
    func testFormatRecoveryClearsDestroyedReusedGuardAfterTapValidationFailure() async throws {
        let hal = TestHALRouteOperations()
        hal.tapObjectIDs = [101, 101, 102]
        let coordinator = makeWorkingRouteCoordinator(hal: hal)
        let output = M1MonitoredOutputIdentity(objectID: 42, persistentUID: "device.uid")

        try await coordinator.start(configuration: .transparentRecovery)
        try await coordinator.stopForOutputFormatRecovery(expectedOutput: output)
        hal.tapDataByObjectID[101] = M1HALTapData(uid: "", format: hal.supportedFormat)
        hal.defaultOutputs = [48_000, 48_000].map { hal.outputData(sampleRate: $0) }
        do {
            try await coordinator.start(
                configuration: .transparentRecovery,
                mode: .outputFormatRecovery(expectedOutput: output)
            )
            XCTFail("invalid replacement tap must fail")
        } catch let error as M1AudioRouteError {
            XCTAssertEqual(error, .invalidTap("unsupported tap UID or format"))
        }

        hal.tapDataByObjectID[102] = M1HALTapData(uid: "tap.retry", format: hal.supportedFormat)
        hal.defaultOutputs = [48_000, 48_000].map { hal.outputData(sampleRate: $0) }
        try await coordinator.start(
            configuration: .transparentRecovery,
            mode: .outputFormatRecovery(expectedOutput: output)
        )
        let runningState = await coordinator.state()
        XCTAssertEqual(
            runningState,
            .running(generation: M1AudioRouteGeneration(rawValue: 3), bridgeGeneration: 3)
        )
        XCTAssertEqual(hal.destroyedTapIDs, [101])
        try await coordinator.stop()
        XCTAssertEqual(hal.destroyedTapIDs, [101, 102])
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

    func testCoordinatorStopFailureRetainsResourcesForRetry() async throws {
        let operations = TestAudioIOOperations()
        let coordinator = makeWorkingRouteCoordinator(
            hal: TestHALRouteOperations(),
            audioOperations: operations
        )
        try await coordinator.start()
        operations.stopOutputFailuresRemaining = 1

        do {
            try await coordinator.stop()
            XCTFail("output stop failure must surface")
        } catch TestFailure.injected {}
        let failedState = await coordinator.state()
        XCTAssertEqual(failedState, .cleanupRequired(generation: .init(rawValue: 1)))

        try await coordinator.stop()
        let finalState = await coordinator.state()
        XCTAssertEqual(finalState, .stopped)
    }

    func testStoppedCoordinatorQueriesPublicationEffectsAndStopsAreSafeNoOps() async throws {
        let coordinator = makeWorkingRouteCoordinator(hal: TestHALRouteOperations())
        XCTAssertEqual(M1OutputFormatStabilityTiming.production.maximumObservations, 6)
        try await M1OutputFormatStabilityTiming.production.sleep(0)

        let outputLayout = await coordinator.outputLayout()
        let processingDiagnostics = await coordinator.processingDiagnostics()
        let diagnostics = try await coordinator.diagnostics()
        let publication = await coordinator.waitForPublication(configurationGeneration: 1)
        XCTAssertNil(outputLayout)
        XCTAssertNil(processingDiagnostics)
        XCTAssertNil(diagnostics)
        XCTAssertFalse(publication)
        await coordinator.discardPendingPublication()
        try await coordinator.stop()
        try await coordinator.stopForOutputFormatRecovery(
            expectedOutput: .init(objectID: 42, persistentUID: "output")
        )
        let stoppedGeneration = try await coordinator.stop(bridgeGeneration: 1)
        XCTAssertFalse(stoppedGeneration)

        do {
            try await coordinator.setEffectsEnabled(false)
            XCTFail("stopped effects update must fail")
        } catch let error as M1AudioIOError {
            XCTAssertEqual(error, .generationMismatch)
        }
        do {
            _ = try await coordinator.activateEffects(
                preparation: .waitingForOutput,
                activationToken: M1EffectsActivationToken()
            )
            XCTFail("stopped activation must fail")
        } catch let error as M1AudioIOError {
            XCTAssertEqual(error, .generationMismatch)
        }
    }

    func testPreparedStateFactoryRejectsChannelStageTotalAndNativeValidationErrors() throws {
        XCTAssertThrowsError(try M1RuntimePreparedStateFactory.create(stagesByChannel: []))
        let gain = M1CompiledProcessingStage.gain(nodeID: UUID(), linearGain: 1)
        XCTAssertThrowsError(try M1RuntimePreparedStateFactory.create(
            stagesByChannel: [Array(repeating: gain, count: Int(EAUM1_MAX_STAGES_PER_CHANNEL) + 1)]
        ))
        XCTAssertThrowsError(try M1RuntimePreparedStateFactory.create(
            stagesByChannel: Array(
                repeating: Array(repeating: gain, count: Int(EAUM1_MAX_STAGES_PER_CHANNEL)),
                count: 9
            )
        ))
        XCTAssertThrowsError(try M1RuntimePreparedStateFactory.create(
            stagesByChannel: [[.gain(nodeID: UUID(), linearGain: .nan)]]
        ))
        XCTAssertThrowsError(try M1RuntimePreparedStateFactory.create(
            stagesByChannel: [[.convolution(nodeID: UUID(), taps: [])]]
        ))

        let prepared = try M1RuntimePreparedStateFactory.create(stagesByChannel: [[
            .biquad(
                nodeID: UUID(),
                bandIndex: 0,
                coefficients: M1BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
            ),
            .convolution(nodeID: UUID(), taps: [1]),
        ]])
        EAUM1PreparedStateDestroy(prepared)
    }

    func testRuntimeLeaseAccessCoversPublicationDiagnosticsMaintenanceAndBypassReplacement() async throws {
        let factory = RealTestRuntimeFactory()
        let initialState = M1RuntimeInitialState(
            stagesByChannel: [[], []],
            effectsEnabled: true
        )
        let lease = try factory.createRuntime(
            bridgeGeneration: 77,
            initialState: initialState,
            maximumFrameCount: 256,
            sampleRate: 48_000
        )
        defer { factory.destroyRuntime(lease) }
        let access = M1RuntimeLeaseAccess(stopHandler: { _, _ in })
        let installed = await access.install(lease)
        XCTAssertTrue(installed)

        let publication = try await access.publish(
            stagesByChannel: [
                [.gain(nodeID: UUID(), linearGain: 0.5)],
                [.gain(nodeID: UUID(), linearGain: 0.5)],
            ],
            configurationGeneration: 2,
            bridgeGeneration: 77
        )
        XCTAssertEqual(publication.disposition, .active)
        let generations = await access.configurationGenerations(bridgeGeneration: 77)
        XCTAssertEqual(generations, .init(active: 2, pending: nil))
        _ = try await access.diagnostics(bridgeGeneration: 77)
        XCTAssertEqual(processRuntime(lease.pointer), EAUM1Status(EAUM1StatusOK))
        XCTAssertEqual(processRuntime(lease.pointer), EAUM1Status(EAUM1StatusOK))
        var maintenanceStep = await access.performMaintenance(
            ticket: publication.retirementTicket ?? 0,
            bridgeGeneration: 77
        )
        for _ in 0..<4 {
            guard case let .maintenanceRequired(ticket) = maintenanceStep else { break }
            maintenanceStep = await access.performMaintenance(ticket: ticket, bridgeGeneration: 77)
        }
        XCTAssertEqual(maintenanceStep, .completed)

        try await access.setEffectsEnabled(false, bridgeGeneration: 77)
        let preCallbackState = try await access.effectsState(bridgeGeneration: 77)
        XCTAssertEqual(preCallbackState, .active)
        XCTAssertEqual(processRuntime(lease.pointer), EAUM1Status(EAUM1StatusOK))
        XCTAssertEqual(processRuntime(lease.pointer), EAUM1Status(EAUM1StatusOK))
        let bypassedState = try await access.effectsState(bridgeGeneration: 77)
        XCTAssertEqual(bypassedState, .bypassed)
        let canReplace = try await access.canReplaceWhileBypassed(bridgeGeneration: 77)
        XCTAssertTrue(canReplace)
        let replaced = try await access.replaceWhileBypassed(
            stagesByChannel: [[], []],
            configurationGeneration: 3,
            bridgeGeneration: 77
        )
        XCTAssertTrue(replaced)
        try await access.enableEffects(
            bridgeGeneration: 77,
            activationToken: M1EffectsActivationToken()
        )
        await access.discardPendingPrepared(bridgeGeneration: 77)
    }

    func testRuntimeLeaseAccessRejectsStaleGenerationsAndCancelledActivation() async throws {
        let factory = RealTestRuntimeFactory()
        let lease = try factory.createRuntime(
            bridgeGeneration: 88,
            initialState: .init(stagesByChannel: [[], []], effectsEnabled: true),
            maximumFrameCount: 256,
            sampleRate: 48_000
        )
        defer { factory.destroyRuntime(lease) }
        let stopRecorder = RetirementStopRecorder()
        let access = M1RuntimeLeaseAccess { reason, generation in
            await stopRecorder.record(reason: reason, generation: generation)
        }
        let installed = await access.install(lease)
        XCTAssertTrue(installed)

        do {
            _ = try await access.publish(
                stagesByChannel: [[], []],
                configurationGeneration: 1,
                bridgeGeneration: 999
            )
            XCTFail("stale publish must fail")
        } catch let error as M1AudioIOError {
            XCTAssertEqual(error, .generationMismatch)
        }
        do {
            _ = try await access.canReplaceWhileBypassed(bridgeGeneration: 999)
            XCTFail("stale preflight must fail")
        } catch let error as M1AudioIOError {
            XCTAssertEqual(error, .generationMismatch)
        }
        do {
            _ = try await access.replaceWhileBypassed(
                stagesByChannel: [[], []],
                configurationGeneration: nil,
                bridgeGeneration: 999
            )
            XCTFail("stale replacement must fail")
        } catch let error as M1AudioIOError {
            XCTAssertEqual(error, .generationMismatch)
        }
        let activeCanReplace = try await access.canReplaceWhileBypassed(bridgeGeneration: 88)
        XCTAssertFalse(activeCanReplace)

        do {
            _ = try await access.publish(
                stagesByChannel: [[]],
                configurationGeneration: 2,
                bridgeGeneration: 88
            )
            XCTFail("topology mismatch must fail")
        } catch let error as M1AudioIOError {
            guard case .invalidConfiguration = error else {
                return XCTFail("unexpected publication error: \(error)")
            }
        }
        do {
            try await access.enableEffects(
                bridgeGeneration: 999,
                activationToken: M1EffectsActivationToken()
            )
            XCTFail("stale activation must fail")
        } catch let error as M1AudioIOError {
            XCTAssertEqual(error, .generationMismatch)
        }
        let staleTicket = await access.performMaintenance(ticket: 999, bridgeGeneration: 88)
        guard case .failed = staleTicket else {
            return XCTFail("stale maintenance ticket must fail")
        }

        let cancelled = M1EffectsActivationToken()
        cancelled.invalidate()
        do {
            try await access.enableEffects(bridgeGeneration: 88, activationToken: cancelled)
            XCTFail("cancelled activation must fail")
        } catch is CancellationError {}
        do {
            try await access.setEffectsEnabled(false, bridgeGeneration: 999)
            XCTFail("stale effects update must fail")
        } catch let error as M1AudioIOError {
            XCTAssertEqual(error, .generationMismatch)
        }
        do {
            _ = try await access.effectsState(bridgeGeneration: 999)
            XCTFail("stale effects query must fail")
        } catch let error as M1AudioIOError {
            XCTAssertEqual(error, .generationMismatch)
        }
        let staleGenerations = await access.configurationGenerations(bridgeGeneration: 999)
        XCTAssertNil(staleGenerations)
        do {
            _ = try await access.diagnostics(bridgeGeneration: 999)
            XCTFail("stale diagnostics must fail")
        } catch let error as M1AudioIOError {
            XCTAssertEqual(error, .generationMismatch)
        }
        let staleMaintenance = await access.performMaintenance(ticket: 1, bridgeGeneration: 999)
        XCTAssertEqual(staleMaintenance, .bridgeGenerationChanged)
        await access.discardPendingPrepared(bridgeGeneration: 999)
        await access.requestRecoverableStop(
            reason: .effectsBypassTimedOut,
            bridgeGeneration: 999
        )
        let staleStopEvents = await stopRecorder.events()
        XCTAssertTrue(staleStopEvents.isEmpty)
        await access.requestRecoverableStop(
            reason: .effectsBypassTimedOut,
            bridgeGeneration: 88
        )
        let stopEvents = await stopRecorder.events()
        XCTAssertEqual(stopEvents.count, 1)
    }

    func testCoordinatorExposesLayoutDiagnosticsAndPublicationControl() async throws {
        let hal = TestHALRouteOperations()
        let audioOperations = TestAudioIOOperations()
        let coordinator = makeWorkingRouteCoordinator(
            hal: hal,
            audioOperations: audioOperations
        )
        try await coordinator.start()
        await coordinator.discardPendingPublication()

        let outputLayout = await coordinator.outputLayout()
        let diagnostics = try await coordinator.diagnostics()
        XCTAssertEqual(outputLayout?.channels.count, 2)
        XCTAssertNotNil(diagnostics)

        let configuration = M1ConfigurationSnapshot(
            effectsEnabled: true,
            nodes: [M1PreampNode(id: UUID(), isEnabled: true, gainDB: -3, channels: .all)]
        )
        let preparation = try await coordinator.prepare(configuration: configuration)
        let publication = try await coordinator.publish(
            preparation: preparation,
            configurationGeneration: 2
        )
        XCTAssertNotNil(publication)
        let runtime = try XCTUnwrap(audioOperations.runtime)
        XCTAssertEqual(processRuntime(runtime.pointer), EAUM1Status(EAUM1StatusOK))
        XCTAssertEqual(processRuntime(runtime.pointer), EAUM1Status(EAUM1StatusOK))
        let published = await coordinator.waitForPublication(configurationGeneration: 2)
        let processingDiagnostics = await coordinator.processingDiagnostics()
        XCTAssertTrue(published)
        XCTAssertNil(processingDiagnostics)
        await coordinator.discardPendingPublication()
        try await coordinator.stop()
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
    var aggregateDataOverride: M1HALAggregateData?
    var aggregateDestroyFailuresRemaining = 0
    var aggregateDestroyAttempts: [UInt32] = []
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
        if let aggregateDataOverride { return aggregateDataOverride }
        return M1HALAggregateData(
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
        aggregateDestroyAttempts.append(objectID)
        if aggregateDestroyFailuresRemaining > 0 {
            aggregateDestroyFailuresRemaining -= 1
            throw TestFailure.injected
        }
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

    private(set) var runtime: M1RuntimeHandleLease?
    private var outputs: [UUID: OutputDescription] = [:]
    private var runningOutputs: Set<UUID> = []
    var stopOutputFailuresRemaining = 0
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
        self.runtime = runtime
        return M1AudioIOHostHandle()
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
        if stopOutputFailuresRemaining > 0 {
            stopOutputFailuresRemaining -= 1
            throw TestFailure.injected
        }
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

private actor InvalidatingEffectsClock {
    private let token: M1EffectsActivationToken
    private let invalidationCall: Int
    private var callCount = 0

    init(token: M1EffectsActivationToken, invalidationCall: Int) {
        self.token = token
        self.invalidationCall = invalidationCall
    }

    func now() -> UInt64 {
        callCount += 1
        if callCount == invalidationCall { token.invalidate() }
        return 0
    }
}

private actor SequencedEffectsClock {
    private var values: [UInt64]

    init(values: [UInt64]) {
        self.values = values
    }

    func now() -> UInt64 {
        values.count > 1 ? values.removeFirst() : values[0]
    }
}

private actor EffectsTestClock {
    private var value: UInt64 = 0

    func now() -> UInt64 { value }

    func advance(by nanoseconds: UInt64) {
        value &+= nanoseconds
    }
}

private actor RetirementStopRecorder {
    struct Event: Sendable {
        let reason: M1RetirementStopReason
        let generation: UInt64
    }

    private var recorded: [Event] = []

    func record(reason: M1RetirementStopReason, generation: UInt64) {
        recorded.append(Event(reason: reason, generation: generation))
    }

    func events() -> [Event] { recorded }
}

private func processRuntime(_ runtime: OpaquePointer) -> EAUM1Status {
    var samples = [Float](repeating: 0.25, count: 512)
    return samples.withUnsafeMutableBufferPointer { values in
        var buffer = EAUM1AudioBuffer(samples: values.baseAddress, channelCount: 2)
        return EAUM1RuntimeProcess(runtime, &buffer, 1, 256)
    }
}

private enum TestFailure: Error {
    case injected
}
