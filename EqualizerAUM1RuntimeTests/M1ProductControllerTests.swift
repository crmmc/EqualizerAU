import Foundation
import XCTest

final class M1ProductControllerTests: XCTestCase {
    func testDraftEditingHasNoPersistenceOrAudioSideEffects() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)

        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 6)
        try await fixture.controller.addPreamp(nodeID: fixture.secondNodeID)
        try await fixture.controller.movePreamp(id: fixture.secondNodeID, to: 0)

        let snapshot = await fixture.controller.snapshot()
        let commits = await fixture.store.commits
        let calls = await fixture.audio.calls
        XCTAssertEqual(snapshot.draft.nodes.map(\.id), [fixture.secondNodeID, fixture.nodeID])
        XCTAssertEqual(snapshot.draft.nodes[1].gainDB, 6)
        XCTAssertEqual(snapshot.persistence, .modified)
        XCTAssertTrue(commits.isEmpty)
        XCTAssertTrue(calls.isEmpty)
    }

    func testSaveWhileStoppedPersistsCapturedDraftWithoutAudioPublication() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: -3)

        try await fixture.controller.save()

        let commits = await fixture.store.commits
        let snapshot = await fixture.controller.snapshot()
        let calls = await fixture.audio.calls
        XCTAssertEqual(commits.map(\.generation), [1])
        XCTAssertEqual(commits.first?.snapshot.nodes.first?.gainDB, -3)
        XCTAssertEqual(snapshot.persistence, .savedPendingStart)
        XCTAssertFalse(calls.contains("publish"))
    }

    func testStartUsesSavedSnapshotAndDiscoversLayoutOnce() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 4)
        try await fixture.controller.save()

        try await fixture.controller.start()

        let started = await fixture.audio.startedConfigurations
        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(started.first?.nodes.first?.gainDB, 4)
        XCTAssertEqual(snapshot.audio, .running)
        XCTAssertEqual(snapshot.outputLayout?.channels.count, 2)
    }

    func testRunningSavePersistsBeforePublishingCompiledCandidate() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 6)

        try await fixture.controller.save()

        let calls = await fixture.audio.calls
        let commits = await fixture.store.commits
        let publishedGenerations = await fixture.audio.publishedGenerations
        XCTAssertEqual(commits.last?.snapshot.nodes.first?.gainDB, 6)
        XCTAssertEqual(calls.suffix(2), ["prepare", "publish"])
        XCTAssertEqual(publishedGenerations, [1])
    }

    func testEffectsToggleUpdatesRuntimeAndPersistsWithoutPublishingChain() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()

        try await fixture.controller.setEffectsEnabled(false)

        let calls = await fixture.audio.calls
        let commits = await fixture.store.commits
        XCTAssertTrue(calls.contains("effects:false"))
        XCTAssertFalse(calls.contains("publish"))
        XCTAssertEqual(commits.last?.snapshot.effectsEnabled, false)
    }

    func testUncertainCommitFreezesEditingUntilSameGenerationRetry() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 2)
        await fixture.store.setNextResult(.uncertain(
            generation: 1,
            snapshot: M1ConfigurationSnapshot.initial(nodeID: fixture.nodeID),
            bootstrapOrigin: nil
        ))

        try await fixture.controller.save()
        let uncertain = await fixture.controller.snapshot()
        XCTAssertEqual(uncertain.persistence, .uncertain(generation: 1))
        XCTAssertFalse(uncertain.canEdit)
        await XCTAssertThrowsErrorAsync {
            try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 3)
        }

        await fixture.store.setRetryResult(.succeeded(
            generation: 1,
            snapshot: uncertain.draft
        ))
        try await fixture.controller.retryUncertainPersistence()
        let recovered = await fixture.controller.snapshot()
        let retryGenerations = await fixture.store.retryGenerations
        XCTAssertEqual(recovered.persistence, .savedPendingStart)
        XCTAssertTrue(recovered.canEdit)
        XCTAssertEqual(retryGenerations, [1])
    }

    func testStopClearsRunningProjection() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()

        try await fixture.controller.stop()

        let snapshot = await fixture.controller.snapshot()
        let lastCall = await fixture.audio.calls.last
        XCTAssertEqual(snapshot.audio, .stopped)
        XCTAssertNil(snapshot.outputLayout)
        XCTAssertEqual(lastCall, "stop")
    }

    func testEffectsChangesDuringSavePersistOnlyLatestIntentAfterCapturedSave() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 3)
        let gate = ProductTestGate()
        await fixture.store.setCommitGate(gate)

        let saveTask = Task { try await fixture.controller.save() }
        await waitUntil { await fixture.store.commits.count == 1 }
        try await fixture.controller.setEffectsEnabled(false)
        try await fixture.controller.setEffectsEnabled(true)
        try await fixture.controller.setEffectsEnabled(false)
        await gate.open()
        try await saveTask.value

        let commits = await fixture.store.commits
        let publishedGenerations = await fixture.audio.publishedGenerations
        XCTAssertEqual(commits.map(\.generation), [1, 2])
        XCTAssertEqual(commits.map { $0.snapshot.effectsEnabled }, [true, false])
        XCTAssertEqual(publishedGenerations, [1])
        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(snapshot.persistence, .clean)
        XCTAssertFalse(snapshot.draft.effectsEnabled)
    }

    func testStopOvertakesBlockedStartAndLeavesStoppedProjection() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        let gate = ProductTestGate()
        await fixture.audio.setStartGate(gate)

        let startTask = Task { try await fixture.controller.start() }
        await waitUntil { await fixture.audio.calls.contains("start") }
        try await fixture.controller.stop()

        await XCTAssertThrowsErrorAsync { try await startTask.value }
        let snapshot = await fixture.controller.snapshot()
        let calls = await fixture.audio.calls
        XCTAssertEqual(snapshot.audio, .stopped)
        XCTAssertEqual(calls, ["start", "stop"])
    }

    func testEffectsAreUnavailableWhileStartIsInProgress() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        let gate = ProductTestGate()
        await fixture.audio.setStartGate(gate)

        let startTask = Task { try await fixture.controller.start() }
        await waitUntil { await fixture.audio.calls.contains("start") }
        let starting = await fixture.controller.snapshot()
        XCTAssertFalse(starting.canSetEffects)
        await XCTAssertThrowsErrorAsync {
            try await fixture.controller.setEffectsEnabled(false)
        }
        await gate.open()
        try await startTask.value

        let commits = await fixture.store.commits
        XCTAssertTrue(commits.isEmpty)
    }

    func testEditingDuringSaveKeepsLaterDraftModified() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 3)
        let gate = ProductTestGate()
        await fixture.store.setCommitGate(gate)

        let saveTask = Task { try await fixture.controller.save() }
        await waitUntil { await fixture.store.commits.count == 1 }
        let saving = await fixture.controller.snapshot()
        XCTAssertTrue(saving.canEdit)
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 7)
        await gate.open()
        try await saveTask.value

        let commits = await fixture.store.commits
        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(commits.first?.snapshot.nodes.first?.gainDB, 3)
        XCTAssertEqual(snapshot.draft.nodes.first?.gainDB, 7)
        XCTAssertEqual(snapshot.persistence, .modified)
    }

    func testRunningUncertainRetryPublishesConfirmedCandidate() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 5)
        let candidate = await fixture.controller.snapshot().draft
        await fixture.store.setNextResult(.uncertain(
            generation: 1,
            snapshot: candidate,
            bootstrapOrigin: nil
        ))

        try await fixture.controller.save()
        let publishedBeforeRetry = await fixture.audio.publishedGenerations
        XCTAssertTrue(publishedBeforeRetry.isEmpty)
        await fixture.store.setRetryResult(.succeeded(generation: 1, snapshot: candidate))
        try await fixture.controller.retryUncertainPersistence()

        let published = await fixture.audio.publishedGenerations
        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(published, [1])
        XCTAssertEqual(snapshot.persistence, .clean)
    }

    func testRecoveryAllowsUnchangedRepairAndStartsTransparentRuntimeBaseline() async throws {
        let nodeID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let editable = M1ConfigurationSnapshot.initial(nodeID: nodeID)
        let store = ProductStoreFake(bootstrapResult: .recovery(
            editable: editable,
            runtime: .transparentRecovery,
            reason: .initialConfigurationWriteFailed
        ))
        let audio = ProductAudioFake()
        let controller = M1ProductController(store: store, audio: audio)
        await controller.bootstrap(initialNodeID: nodeID)

        let recovery = await controller.snapshot()
        XCTAssertTrue(recovery.canSave)
        XCTAssertFalse(recovery.canSetEffects)
        try await controller.start()

        let started = await audio.startedConfigurations
        XCTAssertEqual(started.first, .transparentRecovery)
        try await controller.stop()
        try await controller.save()
        let commits = await store.commits
        XCTAssertEqual(commits.last?.mode, .repair)
    }

    func testFailedRepairRemainsRepairableAndKeepsEffectsDisabled() async throws {
        let nodeID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let editable = M1ConfigurationSnapshot.initial(nodeID: nodeID)
        let store = ProductStoreFake(bootstrapResult: .recovery(
            editable: editable,
            runtime: .transparentRecovery,
            reason: .initialConfigurationWriteFailed
        ))
        let controller = M1ProductController(store: store, audio: ProductAudioFake())
        await controller.bootstrap(initialNodeID: nodeID)
        await store.setNextResult(.failed(generation: 1, reason: .replaceMain))

        try await controller.save()

        let failed = await controller.snapshot()
        XCTAssertEqual(failed.persistence, .recovery)
        XCTAssertTrue(failed.canSave)
        XCTAssertFalse(failed.canSetEffects)
        try await controller.save()
        let commits = await store.commits
        XCTAssertEqual(commits.map(\.mode), [.repair, .repair])
    }

    func testStartFailurePreservesCleanupRequiredProjection() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        await fixture.audio.setStartFailure(state: .cleanupRequired(
            generation: M1AudioRouteGeneration(rawValue: 1)
        ))

        await XCTAssertThrowsErrorAsync { try await fixture.controller.start() }

        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(snapshot.audio, .cleanupRequired)
        XCTAssertTrue(snapshot.canStop)
        XCTAssertFalse(snapshot.canStart)
    }

    func testPendingPublicationPromotesExpectedDiagnostics() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 4)
        let gate = ProductTestGate()
        await fixture.audio.setPublication(disposition: .pending, gate: gate)

        try await fixture.controller.save()
        let pending = await fixture.controller.snapshot()
        XCTAssertNotNil(pending.expectedDiagnostics)
        await gate.open()
        await fixture.controller.waitForPendingApplication()

        let promoted = await fixture.controller.snapshot()
        XCTAssertNil(promoted.expectedDiagnostics)
        XCTAssertNotNil(promoted.activeDiagnostics)
    }

    func testStopDuringPendingPublicationBecomesSavedPendingStart() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 4)
        let gate = ProductTestGate()
        await fixture.audio.setPublication(disposition: .pending, gate: gate)
        try await fixture.controller.save()

        try await fixture.controller.stop()
        await gate.open()
        await fixture.controller.waitForPendingApplication()

        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(snapshot.audio, .stopped)
        XCTAssertEqual(snapshot.persistence, .savedPendingStart)
    }

    func testLateActivePublicationCannotOverwriteStoppedProjection() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 4)
        let gate = ProductTestGate()
        await fixture.audio.setPublishGate(gate)

        let saveTask = Task { try await fixture.controller.save() }
        await waitUntil { await fixture.audio.calls.contains("publish") }
        try await fixture.controller.stop()
        await gate.open()
        try await saveTask.value

        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(snapshot.audio, .stopped)
        XCTAssertEqual(snapshot.persistence, .savedPendingStart)
        XCTAssertNil(snapshot.activeDiagnostics)
        XCTAssertNil(snapshot.expectedDiagnostics)
    }

    func testShutdownWaitsForAcceptedSaveBeforeStoppingAudio() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 2)
        let gate = ProductTestGate()
        await fixture.store.setCommitGate(gate)

        let saveTask = Task { try await fixture.controller.save() }
        await waitUntil { await fixture.store.commits.count == 1 }
        let shutdownTask = Task { try await fixture.controller.shutdown() }
        await Task.yield()
        let callsBeforeCommit = await fixture.audio.calls
        XCTAssertFalse(callsBeforeCommit.contains("stop"))
        await gate.open()
        try await saveTask.value
        try await shutdownTask.value

        let calls = await fixture.audio.calls
        XCTAssertEqual(calls.last, "stop")
    }

    func testBootstrapIsIdempotent() async {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        await fixture.controller.bootstrap(initialNodeID: fixture.secondNodeID)
        let bootstrapCount = await fixture.store.bootstrapCount
        XCTAssertEqual(bootstrapCount, 1)
    }

    func testPreparationFailureRejectsSaveBeforePersistence() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 3)
        await fixture.audio.setPreparationFailure(true)

        await XCTAssertThrowsErrorAsync { try await fixture.controller.save() }

        let commits = await fixture.store.commits
        let snapshot = await fixture.controller.snapshot()
        XCTAssertTrue(commits.isEmpty)
        XCTAssertEqual(snapshot.persistence, .modified)
    }

    func testSaveWithoutOutputPersistsThenRetriesDiscoveryWithoutAnotherCommit() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: -2)
        await fixture.audio.setOutputAvailable(false)

        try await fixture.controller.save()
        let waiting = await fixture.controller.snapshot()
        let commitsBeforeRetry = await fixture.store.commits.count
        XCTAssertEqual(waiting.persistence, .waitingForOutput)
        XCTAssertEqual(commitsBeforeRetry, 1)

        await fixture.audio.setOutputAvailable(true)
        try await fixture.controller.retryOutputDiscovery()
        let retried = await fixture.controller.snapshot()
        let commitsAfterRetry = await fixture.store.commits.count
        XCTAssertEqual(retried.persistence, .savedPendingStart)
        XCTAssertEqual(commitsAfterRetry, 1)
    }

    func testSaveCanRetryOutputDiscoveryWithoutAnotherEdit() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: -2)
        await fixture.audio.setOutputAvailable(false)
        try await fixture.controller.save()

        let waiting = await fixture.controller.snapshot()
        XCTAssertTrue(waiting.canSave)
        await fixture.audio.setOutputAvailable(true)
        try await fixture.controller.save()

        let snapshot = await fixture.controller.snapshot()
        let commits = await fixture.store.commits
        XCTAssertEqual(snapshot.persistence, .savedPendingStart)
        XCTAssertEqual(commits.count, 2)
    }

    func testFailedNodeSaveEffectsContinuationUsesLastSavedChain() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 8)
        let gate = ProductTestGate()
        await fixture.store.setCommitGate(gate)
        await fixture.store.setNextResult(.failed(generation: 1, reason: .replaceMain))

        let saveTask = Task { try await fixture.controller.save() }
        await waitUntil { await fixture.store.commits.count == 1 }
        try await fixture.controller.setEffectsEnabled(false)
        await gate.open()
        try await saveTask.value

        let commits = await fixture.store.commits
        XCTAssertEqual(commits.map(\.generation), [1, 2])
        XCTAssertEqual(commits[0].snapshot.nodes.first?.gainDB, 8)
        XCTAssertEqual(commits[1].snapshot.nodes.first?.gainDB, 0)
        XCTAssertFalse(commits[1].snapshot.effectsEnabled)
        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(snapshot.persistence, .modified)
    }

    func testShutdownClosesAdmissionWhileWaitingForAcceptedSave() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 2)
        let gate = ProductTestGate()
        await fixture.store.setCommitGate(gate)
        let saveTask = Task { try await fixture.controller.save() }
        await waitUntil { await fixture.store.commits.count == 1 }

        let shutdownTask = Task { try await fixture.controller.shutdown() }
        await waitUntil { !(await fixture.controller.snapshot().canEdit) }
        await XCTAssertThrowsErrorAsync {
            try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 4)
        }

        await gate.open()
        try await saveTask.value
        try await shutdownTask.value
    }

    func testShutdownWaitsForBootstrapPersistence() async throws {
        let fixture = makeFixture()
        let gate = ProductTestGate()
        await fixture.store.setBootstrapGate(gate)

        let bootstrapTask = Task { await fixture.controller.bootstrap(initialNodeID: fixture.nodeID) }
        await waitUntil { await fixture.store.bootstrapCount == 1 }
        let shutdownTask = Task { try await fixture.controller.shutdown() }
        await Task.yield()
        let callsBeforeBootstrap = await fixture.audio.calls
        XCTAssertFalse(callsBeforeBootstrap.contains("stop"))

        await gate.open()
        await bootstrapTask.value
        try await shutdownTask.value
    }

    func testShutdownRejectsBootstrapThatArrivesAfterTerminationBegins() async throws {
        let fixture = makeFixture()

        try await fixture.controller.shutdown()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)

        let bootstrapCount = await fixture.store.bootstrapCount
        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(bootstrapCount, 0)
        XCTAssertFalse(snapshot.canEdit)
    }

    func testRecoverableMaintenanceStopConvergesProductProjection() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()

        await fixture.controller.handleRecoverableStop(
            bridgeGeneration: 1,
            reason: .maintenanceFailed(ticket: 1, status: -1)
        )

        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(snapshot.audio, .stopped)
        XCTAssertEqual(snapshot.persistence, .savedPendingStart)
        XCTAssertTrue(snapshot.canStart)
        XCTAssertNil(snapshot.activeDiagnostics)
    }
}

private struct ProductFixture {
    let nodeID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let secondNodeID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    let store: ProductStoreFake
    let audio: ProductAudioFake
    let controller: M1ProductController
}

private func makeFixture() -> ProductFixture {
    let nodeID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let store = ProductStoreFake(bootstrapResult: .loaded(.initial(nodeID: nodeID)))
    let audio = ProductAudioFake()
    return ProductFixture(store: store, audio: audio, controller: M1ProductController(store: store, audio: audio))
}

private actor ProductStoreFake: M1ConfigurationStoring {
    struct Commit: Sendable {
        let generation: UInt64
        let snapshot: M1ConfigurationSnapshot
        let mode: M1ConfigurationCommitMode
    }

    let bootstrapResult: M1ConfigurationBootstrapResult
    var commits: [Commit] = []
    var retryGenerations: [UInt64] = []
    var bootstrapCount = 0
    private var nextResult: M1ConfigurationCommitResult?
    private var retryResult: M1ConfigurationCommitResult?
    private var commitGate: ProductTestGate?
    private var bootstrapGate: ProductTestGate?

    init(bootstrapResult: M1ConfigurationBootstrapResult) {
        self.bootstrapResult = bootstrapResult
    }

    func bootstrap(initialNodeID: UUID) async -> M1ConfigurationBootstrapResult {
        bootstrapCount += 1
        if let bootstrapGate { await bootstrapGate.wait() }
        return bootstrapResult
    }

    func commit(
        _ candidate: M1EncodedConfiguration,
        generation: UInt64,
        mode: M1ConfigurationCommitMode
    ) async -> M1ConfigurationCommitResult {
        commits.append(Commit(generation: generation, snapshot: candidate.snapshot, mode: mode))
        if let commitGate { await commitGate.wait() }
        if let nextResult {
            self.nextResult = nil
            return nextResult
        }
        return .succeeded(generation: generation, snapshot: candidate.snapshot)
    }

    func retryUncertain(generation: UInt64) -> M1ConfigurationCommitResult {
        retryGenerations.append(generation)
        return retryResult ?? .failed(generation: generation, reason: .persistenceRestricted)
    }

    func setNextResult(_ result: M1ConfigurationCommitResult) { nextResult = result }
    func setRetryResult(_ result: M1ConfigurationCommitResult) { retryResult = result }
    func setCommitGate(_ gate: ProductTestGate?) { commitGate = gate }
    func setBootstrapGate(_ gate: ProductTestGate?) { bootstrapGate = gate }
}

private actor ProductAudioFake: M1ProductAudioControlling {
    var calls: [String] = []
    var startedConfigurations: [M1ConfigurationSnapshot] = []
    var publishedGenerations: [UInt64] = []
    private var running = false
    private var startCancellationRequested = false
    private var startGate: ProductTestGate?
    private var startFailureState: M1NativeAudioRouteState?
    private var publicationDisposition: M1PreparedPublicationDisposition = .active
    private var publicationGate: ProductTestGate?
    private var publishGate: ProductTestGate?
    private var outputAvailable = true
    private var preparationFails = false
    private let layout = M1OutputLayoutSnapshot(
        sampleRate: 48_000,
        maximumFrameCount: 256,
        bufferChannelCounts: [2],
        semanticPositionsByChannelIndex: [.left, .right]
    )!

    func state() -> M1NativeAudioRouteState {
        if let startFailureState { return startFailureState }
        return running
            ? .running(generation: M1AudioRouteGeneration(rawValue: 1), bridgeGeneration: 1)
            : .stopped
    }

    func start(configuration: M1ConfigurationSnapshot) async throws {
        calls.append("start")
        startedConfigurations.append(configuration)
        if let startGate { await startGate.wait() }
        if startCancellationRequested { throw CancellationError() }
        if startFailureState != nil { throw ProductAudioFakeError.startFailed }
        running = true
    }

    func stop() async {
        calls.append("stop")
        startCancellationRequested = true
        await startGate?.open()
        running = false
    }

    func stop(bridgeGeneration: UInt64) async {
        guard bridgeGeneration == 1 else { return }
        await stop()
    }

    func outputLayout() -> M1OutputLayoutSnapshot? {
        calls.append("layout")
        return running ? layout : nil
    }

    func prepare(configuration: M1ConfigurationSnapshot) throws -> M1AudioConfigurationPreparation {
        calls.append("prepare")
        if preparationFails { throw ProductAudioFakeError.preparationFailed }
        guard outputAvailable else { return .waitingForOutput }
        let compiled = try M1ProcessingBuilder.build(nodes: configuration.nodes, layout: layout)
        return M1AudioConfigurationPreparation(
            layout: layout,
            compiled: compiled,
            bridgeGeneration: running ? 1 : nil
        )
    }

    func publish(
        preparation: M1AudioConfigurationPreparation,
        configurationGeneration: UInt64
    ) async throws -> M1PreparedPublication? {
        calls.append("publish")
        if let publishGate { await publishGate.wait() }
        guard preparation.bridgeGeneration == 1, let compiled = preparation.compiled else { return nil }
        publishedGenerations.append(configurationGeneration)
        return M1PreparedPublication(
            disposition: publicationDisposition,
            diagnostics: compiled.diagnostics
        )
    }

    func setEffectsEnabled(_ enabled: Bool) {
        calls.append("effects:\(enabled)")
    }

    func waitForPublication(configurationGeneration: UInt64) async -> Bool {
        await publicationGate?.wait()
        return publishedGenerations.contains(configurationGeneration)
    }

    func setStartGate(_ gate: ProductTestGate?) { startGate = gate }
    func setStartFailure(state: M1NativeAudioRouteState) { startFailureState = state }
    func setOutputAvailable(_ available: Bool) { outputAvailable = available }
    func setPreparationFailure(_ fails: Bool) { preparationFails = fails }
    func setPublication(disposition: M1PreparedPublicationDisposition, gate: ProductTestGate?) {
        publicationDisposition = disposition
        publicationGate = gate
    }
    func setPublishGate(_ gate: ProductTestGate?) { publishGate = gate }
}

private enum ProductAudioFakeError: Error {
    case startFailed
    case preparationFailed
}

private actor ProductTestGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}

private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: () async -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()), clock.now < deadline {
        await Task.yield()
    }
    let fulfilled = await condition()
    XCTAssertTrue(fulfilled)
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
