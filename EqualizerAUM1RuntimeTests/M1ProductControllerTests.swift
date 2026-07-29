import Foundation
import XCTest

final class M1ProductControllerTests: XCTestCase {
    @MainActor
    func testPendingEditorCommitCoordinatorCommitsRegisteredEditorBeforeUnregister() {
        let coordinator = M1PendingEditorCommitCoordinator()
        var commitCount = 0
        let id = coordinator.register { commitCount += 1 }

        coordinator.commitPendingEditor()
        XCTAssertEqual(commitCount, 1)

        coordinator.unregister(id)
        coordinator.commitPendingEditor()
        XCTAssertEqual(commitCount, 1)
    }

    func testApplicationLanguageRawValuesRemainStable() {
        XCTAssertEqual(
            M1ApplicationLanguage.allCases.map(\.rawValue),
            ["system", "english", "simplifiedChinese"]
        )
        XCTAssertEqual(M1ApplicationLanguage.defaultsKey, "applicationLanguage")
    }

    func testApplicationLanguageUsesExplicitSupportedLocales() {
        XCTAssertEqual(M1ApplicationLanguage.english.locale.identifier, "en")
        XCTAssertEqual(M1ApplicationLanguage.simplifiedChinese.locale.identifier, "zh-Hans")
    }

    func testBootstrapDiscoversAvailableOutputWithoutStartingAudio() async {
        let fixture = makeFixture()

        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)

        let snapshot = await fixture.controller.snapshot()
        let calls = await fixture.audio.calls
        XCTAssertNil(snapshot.outputLayout)
        XCTAssertEqual(snapshot.availableOutputLayout?.channels.map(\.identifier.rawValue), ["L", "R"])
        XCTAssertTrue(calls.isEmpty)
    }

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

    func testConvolutionAddAndReplaceOnlyMutateDraft() async throws {
        let fixture = makeFixture()
        let convolutionID = UUID()
        let firstIR = productConvolutionIR(storageID: UUID(), fileName: "first.wav")
        let secondIR = productConvolutionIR(storageID: UUID(), fileName: "second.wav")
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)

        try await fixture.controller.addConvolution(nodeID: convolutionID, ir: firstIR)
        try await fixture.controller.setConvolutionIR(id: convolutionID, ir: secondIR)

        let snapshot = await fixture.controller.snapshot()
        let commits = await fixture.store.commits
        let calls = await fixture.audio.calls
        XCTAssertEqual(snapshot.draft.nodes.map(\.kind), [.preamp, .convolution])
        XCTAssertEqual(snapshot.draft.nodes.last?.convolutionIR, secondIR)
        XCTAssertEqual(snapshot.persistence, .modified)
        XCTAssertTrue(commits.isEmpty)
        XCTAssertTrue(calls.isEmpty)
    }

    func testConvolutionDraftPrepareFailureKeepsSavedConfigurationAndActiveChain() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        let before = await fixture.controller.snapshot()
        let convolutionID = UUID()
        let firstIR = productConvolutionIR(storageID: UUID(), fileName: "first.wav")
        let secondIR = productConvolutionIR(storageID: UUID(), fileName: "second.wav")
        try await fixture.controller.addConvolution(nodeID: convolutionID, ir: firstIR)
        try await fixture.controller.setConvolutionIR(id: convolutionID, ir: secondIR)
        await fixture.audio.setPreparationFailure(true)

        await XCTAssertThrowsErrorAsync { try await fixture.controller.save() }

        let after = await fixture.controller.snapshot()
        let commits = await fixture.store.commits
        let published = await fixture.audio.publishedGenerations
        XCTAssertTrue(commits.isEmpty)
        XCTAssertTrue(published.isEmpty)
        XCTAssertEqual(after.persistence, .modified)
        XCTAssertEqual(after.activeDiagnostics, before.activeDiagnostics)
        XCTAssertEqual(after.activeConfigurationGeneration, before.activeConfigurationGeneration)
        XCTAssertEqual(after.draft.nodes.last?.convolutionIR, secondIR)
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

    func testCancelledSaveDoesNotPersistAfterPreparationReturns() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        let gate = ProductTestGate()
        await fixture.audio.setPreparationGate(gate)
        let save = Task { try await fixture.controller.save() }
        await waitUntil { await fixture.audio.calls.contains("prepare") }

        save.cancel()
        await gate.open()
        do {
            try await save.value
            XCTFail("cancelled save must fail")
        } catch is CancellationError {}

        let commits = await fixture.store.commits
        XCTAssertTrue(commits.isEmpty)
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

    func testRealtimeDiagnosticsRefreshAndStopClearsSnapshot() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()

        try await fixture.controller.refreshDiagnostics()
        let running = await fixture.controller.snapshot()
        XCTAssertEqual(running.realtimeDiagnostics?.io.overflowedBlocks, 1)
        XCTAssertEqual(running.realtimeDiagnostics?.io.underrunBlocks, 2)
        XCTAssertEqual(running.realtimeDiagnostics?.io.droppedBacklogFrames, 3)
        XCTAssertEqual(running.realtimeDiagnostics?.runtime.nonFiniteInputSamples, 6)
        XCTAssertEqual(running.realtimeDiagnostics?.runtime.saturatedOutputSamples, 7)
        XCTAssertEqual(running.realtimeDiagnostics?.runtime.invalidProcessCalls, 8)

        try await fixture.controller.stop()
        let stopped = await fixture.controller.snapshot()
        XCTAssertNil(stopped.realtimeDiagnostics)
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

    func testPublishFailureLeavesSavedConfigurationPendingRestart() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 6)
        await fixture.audio.setPublishFailure(true)

        await XCTAssertThrowsErrorAsync { try await fixture.controller.save() }

        let failed = await fixture.controller.snapshot()
        let commits = await fixture.store.commits
        XCTAssertEqual(commits.last?.snapshot.nodes.first?.gainDB, 6)
        XCTAssertEqual(failed.persistence, .savedPendingStart)
        XCTAssertFalse(failed.hasUnsavedNodes)
        XCTAssertEqual(failed.expectedConfigurationGeneration, 1)
        XCTAssertNotNil(failed.visibleError)

        try await fixture.controller.stop()
        await fixture.audio.setPublishFailure(false)
        try await fixture.controller.start()
        let starts = await fixture.audio.startedConfigurations
        XCTAssertEqual(starts.last?.nodes.first?.gainDB, 6)
    }

    func testGraphicEQDraftPublishesScopedConvolutionStagesOnlyAfterSave() async throws {
        let fixture = makeFixture()
        let channelsID = UUID()
        let equalizerID = UUID()
        let points = M1GraphicEQContract.legacyFlatPoints.enumerated().map { index, point in
            M1GraphicEQPoint(
                frequencyHz: point.frequencyHz,
                gainDB: index == 8 ? 6 : point.gainDB
            )
        }
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        try await fixture.controller.addChannels(
            nodeID: channelsID,
            selection: .identifiers([M1ChannelIdentifier("L")!])
        )
        try await fixture.controller.addGraphicEQ(nodeID: equalizerID)
        try await fixture.controller.setGraphicEQPoints(id: equalizerID, points: points)

        var commits = await fixture.store.commits
        var publishedStages = await fixture.audio.publishedStagesByChannel
        XCTAssertTrue(commits.isEmpty)
        XCTAssertTrue(publishedStages.isEmpty)

        try await fixture.controller.save()

        commits = await fixture.store.commits
        publishedStages = await fixture.audio.publishedStagesByChannel
        XCTAssertEqual(commits.last?.snapshot.nodes.map(\.kind), [.preamp, .channels, .graphicEQ])
        XCTAssertEqual(commits.last?.snapshot.nodes.last?.graphicEQPoints, points)
        XCTAssertEqual(publishedStages.count, 1)
        XCTAssertEqual(publishedStages[0][0].count, 1)
        XCTAssertTrue(publishedStages[0][1].isEmpty)
        guard case let .convolution(nodeID, taps) = publishedStages[0][0][0] else {
            return XCTFail("Expected a scoped Graphic EQ convolution")
        }
        XCTAssertEqual(nodeID, equalizerID)
        XCTAssertEqual(taps.count, M1ProcessingBuilder.graphicEQTapCount)
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

    func testProcessingSwitchBypassesAndRestoresWithoutRestartingEngine() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()

        try await fixture.controller.setProcessingEnabled(false)
        var snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(snapshot.audio, .running)
        XCTAssertFalse(snapshot.processingEnabled)

        try await fixture.controller.setProcessingEnabled(true)
        snapshot = await fixture.controller.snapshot()
        let calls = await fixture.audio.calls
        XCTAssertEqual(snapshot.audio, .running)
        XCTAssertTrue(snapshot.processingEnabled)
        XCTAssertEqual(calls.filter { $0 == "start" }.count, 1)
        XCTAssertFalse(calls.contains("stop"))
        XCTAssertTrue(calls.contains("effects:false"))
        XCTAssertTrue(calls.contains("effects:true"))
    }

    func testProcessingSwitchStartsStoppedEngineAndChannelsEditIsDraftOnly() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        let channelsID = UUID()
        try await fixture.controller.addChannels(
            before: fixture.nodeID,
            nodeID: channelsID,
            selection: .identifiers([M1ChannelIdentifier("L")!])
        )

        var snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(snapshot.draft.nodes.map(\.kind), [.channels, .preamp])
        XCTAssertEqual(snapshot.persistence, .modified)
        let commitsBeforeSave = await fixture.store.commits
        let callsBeforeSave = await fixture.audio.calls
        XCTAssertTrue(commitsBeforeSave.isEmpty)
        XCTAssertTrue(callsBeforeSave.isEmpty)

        try await fixture.controller.save()
        try await fixture.controller.setProcessingEnabled(true)
        snapshot = await fixture.controller.snapshot()
        let started = await fixture.audio.startedConfigurations
        XCTAssertEqual(snapshot.audio, .running)
        XCTAssertTrue(snapshot.processingEnabled)
        XCTAssertEqual(started.last?.nodes.first?.id, channelsID)
    }

    func testProcessingEnableDoesNotStartWhenEffectsPersistenceFails() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.setEffectsEnabled(false)
        await fixture.store.setNextResult(.failed(generation: 2, reason: .replaceMain))

        await XCTAssertThrowsErrorAsync {
            try await fixture.controller.setProcessingEnabled(true)
        }

        let snapshot = await fixture.controller.snapshot()
        let calls = await fixture.audio.calls
        XCTAssertEqual(snapshot.audio, .stopped)
        XCTAssertFalse(snapshot.processingEnabled)
        XCTAssertFalse(calls.contains("start"))
    }

    func testProcessingProjectionKeepsAppliedStateWhenRuntimeToggleFails() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        await fixture.audio.setEffectsFailure(true)

        await XCTAssertThrowsErrorAsync {
            try await fixture.controller.setProcessingEnabled(false)
        }

        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(snapshot.audio, .running)
        XCTAssertTrue(snapshot.processingEnabled)
        XCTAssertFalse(snapshot.draft.effectsEnabled)

        await fixture.audio.setEffectsFailure(false)
        try await fixture.controller.setProcessingEnabled(false)
        let retried = await fixture.controller.snapshot()
        XCTAssertFalse(retried.processingEnabled)
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
        XCTAssertFalse(snapshot.processingEnabled)
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
        let calls = await fixture.audio.calls
        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(published, [1])
        XCTAssertEqual(calls.filter { $0 == "prepare" }.count, 2)
        XCTAssertEqual(snapshot.persistence, .clean)
    }

    func testUncertainRetryPrepareFailureLeavesConfirmedConfigurationPendingStart() async throws {
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

        await fixture.store.setRetryResult(.succeeded(generation: 1, snapshot: candidate))
        await fixture.audio.setPreparationFailure(true)
        await XCTAssertThrowsErrorAsync {
            try await fixture.controller.retryUncertainPersistence()
        }
        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(snapshot.persistence, .savedPendingStart)
        XCTAssertEqual(snapshot.draft, candidate)
    }

    func testStartClearsStoppedSaveExpectedDiagnostics() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 2)
        try await fixture.controller.save()
        let saved = await fixture.controller.snapshot()
        XCTAssertNotNil(saved.expectedDiagnostics)

        try await fixture.controller.start()
        let started = await fixture.controller.snapshot()
        XCTAssertNil(started.expectedDiagnostics)
        XCTAssertNil(started.expectedConfigurationGeneration)
    }

    func testFailedStartDoesNotRetainStoppedSaveExpectedDiagnostics() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 2)
        try await fixture.controller.save()
        await fixture.audio.setStartFailure(
            state: .cleanupRequired(generation: M1AudioRouteGeneration(rawValue: 1))
        )

        await XCTAssertThrowsErrorAsync {
            try await fixture.controller.start()
        }
        let snapshot = await fixture.controller.snapshot()
        XCTAssertNil(snapshot.expectedDiagnostics)
        XCTAssertNil(snapshot.expectedConfigurationGeneration)
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

    func testNewActivePublicationInvalidatesOlderPendingPromotion() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        let oldGate = ProductTestGate()
        await fixture.audio.setPublication(disposition: .pending, gate: oldGate)
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 2)
        try await fixture.controller.save()

        await fixture.audio.setPublication(disposition: .active, gate: nil)
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 4)
        try await fixture.controller.save()
        await oldGate.open()
        await Task.yield()

        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(snapshot.activeConfigurationGeneration, 2)
        XCTAssertNil(snapshot.expectedConfigurationGeneration)
        XCTAssertEqual(snapshot.draft.nodes[0].gainDB, 4)
    }

    func testNewWaitingOutputSaveInvalidatesOlderPendingPromotion() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        let oldGate = ProductTestGate()
        await fixture.audio.setPublication(disposition: .pending, gate: oldGate)
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 2)
        try await fixture.controller.save()

        await fixture.audio.setOutputAvailable(false)
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 4)
        try await fixture.controller.save()
        await oldGate.open()
        await Task.yield()

        let snapshot = await fixture.controller.snapshot()
        let calls = await fixture.audio.calls
        XCTAssertEqual(snapshot.persistence, .waitingForOutput)
        XCTAssertNotEqual(snapshot.activeConfigurationGeneration, 1)
        XCTAssertNil(snapshot.expectedConfigurationGeneration)
        XCTAssertTrue(calls.contains("discardPending"))
    }

    func testNewUncertainSaveInvalidatesOlderPendingPromotionUntilRetry() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        let oldGate = ProductTestGate()
        await fixture.audio.setPublication(disposition: .pending, gate: oldGate)
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 2)
        try await fixture.controller.save()

        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 4)
        let candidate = await fixture.controller.snapshot().draft
        await fixture.store.setNextResult(.uncertain(
            generation: 2,
            snapshot: candidate,
            bootstrapOrigin: nil
        ))
        try await fixture.controller.save()
        await oldGate.open()
        await Task.yield()

        let snapshot = await fixture.controller.snapshot()
        let calls = await fixture.audio.calls
        XCTAssertEqual(snapshot.persistence, .uncertain(generation: 2))
        XCTAssertNotEqual(snapshot.activeConfigurationGeneration, 1)
        XCTAssertNil(snapshot.expectedConfigurationGeneration)
        XCTAssertTrue(calls.contains("discardPending"))
    }

    func testRapidEffectsToggleKeepsLatestIntentWhileFirstRuntimeUpdateIsBlocked() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        let gate = ProductTestGate()
        await fixture.audio.setEffectsGate(gate)

        let disableTask = Task { try await fixture.controller.setEffectsEnabled(false) }
        await waitUntil { await fixture.audio.calls.contains("effects:false") }
        try await fixture.controller.setEffectsEnabled(true)
        await gate.open()
        try await disableTask.value

        let snapshot = await fixture.controller.snapshot()
        let calls = await fixture.audio.calls
        XCTAssertTrue(snapshot.draft.effectsEnabled)
        XCTAssertEqual(calls.filter { $0.hasPrefix("effects:") }, ["effects:false", "effects:true"])
        let commits = await fixture.store.commits
        XCTAssertEqual(commits.last?.snapshot.effectsEnabled, true)
    }
    func testNodeEditRemainsValidWhileEffectsRuntimeUpdateIsBlocked() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        let gate = ProductTestGate()
        await fixture.audio.setEffectsGate(gate)

        let disableTask = Task { try await fixture.controller.setEffectsEnabled(false) }
        await waitUntil { await fixture.audio.calls.contains("effects:false") }
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 5)
        await gate.open()
        try await disableTask.value

        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(snapshot.draft.nodes.first?.gainDB, 5)
        XCTAssertFalse(snapshot.draft.effectsEnabled)
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
        XCTAssertEqual(snapshot.persistence, .failed("replaceMain"))
        XCTAssertEqual(snapshot.visibleError, .technical("replaceMain"))
        XCTAssertEqual(snapshot.draft.nodes.first?.gainDB, 8)
        XCTAssertEqual(snapshot.draft.effectsEnabled, false)
    }
    func testFailedNodeSaveDoesNotMaskUncertainEffectsContinuation() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        var uncertainEffects = await fixture.controller.snapshot().draft
        uncertainEffects.effectsEnabled = false
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 8)
        let gate = ProductTestGate()
        await fixture.store.setCommitGate(gate)
        await fixture.store.setNextResults([
            .failed(generation: 1, reason: .replaceMain),
            .uncertain(
                generation: 2,
                snapshot: uncertainEffects,
                bootstrapOrigin: nil
            ),
        ])

        let saveTask = Task { try await fixture.controller.save() }
        await waitUntil { await fixture.store.commits.count == 1 }
        try await fixture.controller.setEffectsEnabled(false)
        await gate.open()
        try await saveTask.value

        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(snapshot.persistence, .uncertain(generation: 2))
        XCTAssertEqual(snapshot.visibleError, .configurationDurabilityUncertain)
        XCTAssertFalse(snapshot.canEdit)
    }
    func testOlderPendingPublicationDoesNotMaskUncertainEffectsContinuation() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        let publicationGate = ProductTestGate()
        await fixture.audio.setPublication(disposition: .pending, gate: publicationGate)
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 2)
        try await fixture.controller.save()

        var uncertainEffects = await fixture.controller.snapshot().draft
        uncertainEffects.effectsEnabled = false
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 8)
        let commitGate = ProductTestGate()
        await fixture.store.setCommitGate(commitGate)
        await fixture.store.setNextResults([
            .failed(generation: 2, reason: .replaceMain),
            .uncertain(generation: 3, snapshot: uncertainEffects, bootstrapOrigin: nil),
        ])

        let saveTask = Task { try await fixture.controller.save() }
        await waitUntil { await fixture.store.commits.count == 2 }
        try await fixture.controller.setEffectsEnabled(false)
        await commitGate.open()
        try await saveTask.value
        let beforePromotion = await fixture.controller.snapshot()
        XCTAssertEqual(beforePromotion.persistence, .uncertain(generation: 3))

        await publicationGate.open()
        await fixture.controller.waitForPendingApplication()
        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(snapshot.persistence, .uncertain(generation: 3))
        XCTAssertFalse(snapshot.canEdit)
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

    func testStaleMaintenanceStopDoesNotAffectNewerRunningRoute() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()

        await fixture.controller.handleRecoverableStop(
            bridgeGeneration: 999,
            reason: .maintenanceFailed(ticket: 1, status: -1)
        )

        let snapshot = await fixture.controller.snapshot()
        let calls = await fixture.audio.calls
        XCTAssertEqual(snapshot.audio, .running)
        XCTAssertEqual(snapshot.audioRecovery, .inactive)
        XCTAssertFalse(calls.contains("stop"))
    }

    func testRouteChangeRestartsSavedConfigurationAndRestoresRunningProjection() async throws {
        let fixture = makeFixture(recoveryTiming: immediateRecoveryTiming())
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()

        await fixture.controller.handleAudioLifecycleEvent(.routeChanged)

        let snapshot = await fixture.controller.snapshot()
        let starts = await fixture.audio.startedConfigurations
        let modes = await fixture.audio.startModes
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(modes, [.normal, .normal])
        XCTAssertEqual(snapshot.audio, .running)
        XCTAssertEqual(snapshot.audioRecovery, .inactive)
        XCTAssertNotNil(snapshot.outputLayout)
    }

    func testDeviceListChangeDoesNotEmitRecoveryWhenDefaultOutputIdentityIsUnchanged() {
        let output = M1MonitoredOutputIdentity(objectID: 42, persistentUID: "output-a")

        let event = M1AudioLifecycleEventClassifier.event(
            for: [.deviceList],
            previousOutput: output,
            currentOutput: output
        )

        XCTAssertNil(event)
    }

    func testDeviceListChangeEmitsServiceRecoveryWhenDefaultOutputIdentityChanges() {
        let event = M1AudioLifecycleEventClassifier.event(
            for: [.deviceList],
            previousOutput: M1MonitoredOutputIdentity(objectID: 42, persistentUID: "output-a"),
            currentOutput: M1MonitoredOutputIdentity(objectID: 42, persistentUID: "output-b")
        )

        XCTAssertEqual(event, .systemAudioServicesChanged)
    }

    func testDeviceListChangeEmitsServiceRecoveryWhenDefaultOutputObjectIsRecreated() {
        let event = M1AudioLifecycleEventClassifier.event(
            for: [.deviceList],
            previousOutput: M1MonitoredOutputIdentity(objectID: 42, persistentUID: "output-a"),
            currentOutput: M1MonitoredOutputIdentity(objectID: 84, persistentUID: "output-a")
        )

        XCTAssertEqual(event, .systemAudioServicesChanged)
    }

    func testDefaultOutputPropertyChangeEmitsRouteRecoveryForStableIdentity() {
        let output = M1MonitoredOutputIdentity(objectID: 42, persistentUID: "output-a")

        let event = M1AudioLifecycleEventClassifier.event(
            for: [.defaultOutput, .deviceList],
            previousOutput: output,
            currentOutput: output
        )

        XCTAssertEqual(event, .routeChanged)
    }

    func testOutputFormatPropertyChangeUsesFormatRecoveryEvent() {
        let output = M1MonitoredOutputIdentity(objectID: 42, persistentUID: "output-a")
        XCTAssertEqual(
            M1AudioDevicePropertyEventClassifier.event(for: [.outputFormat], output: output),
            .outputFormatChanged(output)
        )
        XCTAssertEqual(
            M1AudioDevicePropertyEventClassifier.event(for: [.alive], output: output),
            .routeChanged
        )
        XCTAssertEqual(
            M1AudioDevicePropertyEventClassifier.event(
                for: [.alive, .outputFormat],
                output: output
            ),
            .routeChanged
        )
        XCTAssertEqual(
            M1AudioDevicePropertyEventClassifier.event(for: [.outputFormat], output: nil),
            .routeChanged
        )
    }

    func testOutputFormatChangeRestartsWithFormatRecoveryMode() async throws {
        let fixture = makeFixture(recoveryTiming: immediateRecoveryTiming())
        let output = M1MonitoredOutputIdentity(objectID: 42, persistentUID: "output-a")
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()

        await fixture.controller.handleAudioLifecycleEvent(.outputFormatChanged(output))

        let modes = await fixture.audio.startModes
        let handoverStops = await fixture.audio.formatRecoveryStops
        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(modes, [.normal, .outputFormatRecovery(expectedOutput: output)])
        XCTAssertEqual(handoverStops, [output])
        XCTAssertEqual(snapshot.audio, .running)
        XCTAssertEqual(snapshot.audioRecovery, .inactive)
    }

    func testOutputFormatRecoveryExhaustionReleasesHandoverResources() async throws {
        let fixture = makeFixture(recoveryTiming: immediateRecoveryTiming(maximumAttempts: 3))
        let output = M1MonitoredOutputIdentity(objectID: 42, persistentUID: "output-a")
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        await fixture.audio.setStartFailuresRemaining(3)

        await fixture.controller.handleAudioLifecycleEvent(.outputFormatChanged(output))

        let snapshot = await fixture.controller.snapshot()
        let calls = await fixture.audio.calls
        let handoverStops = await fixture.audio.formatRecoveryStops
        XCTAssertEqual(handoverStops, [output])
        XCTAssertEqual(calls.filter { $0 == "stop" }.count, 1)
        XCTAssertEqual(snapshot.audio, .stopped)
        XCTAssertEqual(
            snapshot.audioRecovery,
            .waitingForRetry(reason: .outputFormatChanged(output))
        )
    }

    func testExplicitStopDuringOutputFormatRecoveryBackoffReleasesHandoverResources() async throws {
        let sleepGate = ProductTestGate()
        let timing = M1AudioRecoveryTiming(
            maximumAttempts: 3,
            delayNanoseconds: { _ in 1 },
            sleep: { _ in await sleepGate.wait() }
        )
        let fixture = makeFixture(recoveryTiming: timing)
        let output = M1MonitoredOutputIdentity(objectID: 42, persistentUID: "output-a")
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        await fixture.audio.setStartFailuresRemaining(3)
        let recovery = Task {
            await fixture.controller.handleAudioLifecycleEvent(.outputFormatChanged(output))
        }
        await waitUntil { await fixture.audio.startedConfigurations.count == 2 }

        try await fixture.controller.stop()
        await sleepGate.open()
        await recovery.value

        let snapshot = await fixture.controller.snapshot()
        let calls = await fixture.audio.calls
        XCTAssertEqual(snapshot.audio, .stopped)
        XCTAssertEqual(snapshot.audioRecovery, .inactive)
        XCTAssertEqual(calls.filter { $0 == "stop" }.count, 1)
    }

    func testSleepDuringOutputFormatRecoveryBackoffReleasesHandoverResources() async throws {
        let sleepGate = ProductTestGate()
        let timing = M1AudioRecoveryTiming(
            maximumAttempts: 3,
            delayNanoseconds: { _ in 1 },
            sleep: { _ in await sleepGate.wait() }
        )
        let fixture = makeFixture(recoveryTiming: timing)
        let output = M1MonitoredOutputIdentity(objectID: 42, persistentUID: "output-a")
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        await fixture.audio.setStartFailuresRemaining(3)
        let recovery = Task {
            await fixture.controller.handleAudioLifecycleEvent(.outputFormatChanged(output))
        }
        await waitUntil { await fixture.audio.startedConfigurations.count == 2 }

        await fixture.controller.handleAudioLifecycleEvent(.willSleep)
        await sleepGate.open()
        await recovery.value

        let snapshot = await fixture.controller.snapshot()
        let calls = await fixture.audio.calls
        XCTAssertEqual(snapshot.audio, .stopped)
        XCTAssertEqual(snapshot.audioRecovery, .suspendedForSleep)
        XCTAssertEqual(calls.filter { $0 == "stop" }.count, 1)
    }

    func testMaintenanceStopDuringOutputFormatRecoveryBackoffTerminatesRecovery() async throws {
        let sleepGate = ProductTestGate()
        let timing = M1AudioRecoveryTiming(
            maximumAttempts: 3,
            delayNanoseconds: { _ in 1 },
            sleep: { _ in await sleepGate.wait() }
        )
        let fixture = makeFixture(recoveryTiming: timing)
        let output = M1MonitoredOutputIdentity(objectID: 42, persistentUID: "output-a")
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        await fixture.audio.setStartFailuresRemaining(3)
        let recovery = Task {
            await fixture.controller.handleAudioLifecycleEvent(.outputFormatChanged(output))
        }
        await waitUntil { await fixture.audio.startedConfigurations.count == 2 }

        await fixture.controller.handleRecoverableStop(
            bridgeGeneration: 1,
            reason: .maintenanceFailed(ticket: 1, status: -1)
        )
        await sleepGate.open()
        await recovery.value

        let snapshot = await fixture.controller.snapshot()
        let starts = await fixture.audio.startedConfigurations
        XCTAssertEqual(snapshot.audio, .stopped)
        XCTAssertEqual(
            snapshot.audioRecovery,
            .waitingForRetry(reason: .systemAudioServicesChanged)
        )
        XCTAssertEqual(starts.count, 2)
    }

    func testDeviceListTrackerRetainsOriginalIdentityUntilRetrySucceeds() {
        var tracker = M1AudioDeviceListChangeTracker()
        tracker.begin(
            previousOutput: M1MonitoredOutputIdentity(objectID: 42, persistentUID: "output-a")
        )

        let event = tracker.finish(
            currentOutput: M1MonitoredOutputIdentity(objectID: 84, persistentUID: "output-b")
        )

        XCTAssertEqual(event, .systemAudioServicesChanged)
        XCTAssertNil(tracker.finish(currentOutput: nil))
    }

    func testSleepStopsWithoutRestartingUntilWake() async throws {
        let fixture = makeFixture(recoveryTiming: immediateRecoveryTiming())
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()

        await fixture.controller.handleAudioLifecycleEvent(.willSleep)
        let sleeping = await fixture.controller.snapshot()
        let sleepingStarts = await fixture.audio.startedConfigurations
        XCTAssertEqual(sleeping.audio, .stopped)
        XCTAssertEqual(sleeping.audioRecovery, .suspendedForSleep)
        XCTAssertFalse(sleeping.canStart)
        XCTAssertEqual(sleepingStarts.count, 1)

        await fixture.controller.handleAudioLifecycleEvent(.routeChanged)
        await fixture.controller.handleAudioLifecycleEvent(.systemAudioServicesChanged)
        let stillSleeping = await fixture.controller.snapshot()
        let startsBeforeWake = await fixture.audio.startedConfigurations
        XCTAssertEqual(stillSleeping.audioRecovery, .suspendedForSleep)
        XCTAssertEqual(startsBeforeWake.count, 1)

        await fixture.controller.handleAudioLifecycleEvent(.didWake)
        let awake = await fixture.controller.snapshot()
        let awakeStarts = await fixture.audio.startedConfigurations
        XCTAssertEqual(awake.audio, .running)
        XCTAssertEqual(awake.audioRecovery, .inactive)
        XCTAssertEqual(awakeStarts.count, 2)
    }

    func testAutomaticRecoveryStopsAfterBoundedAttempts() async throws {
        let fixture = makeFixture(recoveryTiming: immediateRecoveryTiming(maximumAttempts: 3))
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        await fixture.audio.setStartFailuresRemaining(3)

        await fixture.controller.handleAudioLifecycleEvent(.systemAudioServicesChanged)

        let snapshot = await fixture.controller.snapshot()
        let starts = await fixture.audio.startedConfigurations
        XCTAssertEqual(starts.count, 4)
        XCTAssertEqual(snapshot.audio, .stopped)
        XCTAssertEqual(
            snapshot.audioRecovery,
            .waitingForRetry(reason: .systemAudioServicesChanged)
        )
        XCTAssertNotNil(snapshot.visibleError)
        XCTAssertTrue(snapshot.canStart)

        await fixture.controller.handleAudioLifecycleEvent(.routeChanged)
        let startsAfterLaterEvent = await fixture.audio.startedConfigurations
        XCTAssertEqual(startsAfterLaterEvent.count, 4)
    }

    func testPermissionFailureDoesNotRetryAutomatically() async throws {
        let fixture = makeFixture(recoveryTiming: immediateRecoveryTiming(maximumAttempts: 3))
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        await fixture.audio.setPermissionFailure(true)

        await fixture.controller.handleAudioLifecycleEvent(.routeChanged)

        let snapshot = await fixture.controller.snapshot()
        let starts = await fixture.audio.startedConfigurations
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(snapshot.audioRecovery, .permissionRequired)
        XCTAssertFalse(snapshot.processingEnabled)
    }

    func testApplicationActivationPermissionProbeSuccessKeepsRunningRoute() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()

        await fixture.controller.handleApplicationActivation()

        let snapshot = await fixture.controller.snapshot()
        let verificationCount = await fixture.audio.permissionVerificationCount
        let calls = await fixture.audio.calls
        XCTAssertEqual(snapshot.audio, .running)
        XCTAssertEqual(snapshot.audioRecovery, .inactive)
        XCTAssertEqual(verificationCount, 1)
        XCTAssertEqual(calls.last, "verifyPermission")
    }

    func testApplicationActivationPermissionDenialStopsRouteAndRequiresPermission() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        await fixture.audio.setPermissionVerificationError(
            M1AudioRouteError.audioCapturePermissionDenied
        )

        await fixture.controller.handleApplicationActivation()

        let snapshot = await fixture.controller.snapshot()
        let calls = await fixture.audio.calls
        XCTAssertEqual(snapshot.audio, .stopped)
        XCTAssertEqual(snapshot.audioRecovery, .permissionRequired)
        XCTAssertFalse(snapshot.processingEnabled)
        XCTAssertTrue(snapshot.canStart)
        XCTAssertEqual(Array(calls.suffix(2)), ["verifyPermission", "stop"])
    }

    func testApplicationActivationProbeErrorStopsRouteAndWaitsForExplicitRetry() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        await fixture.audio.setPermissionVerificationError(ProductAudioFakeError.permissionProbeFailed)

        await fixture.controller.handleApplicationActivation()

        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(snapshot.audio, .stopped)
        XCTAssertEqual(
            snapshot.audioRecovery,
            .waitingForRetry(reason: .systemAudioServicesChanged)
        )
        guard case let .capturePermissionVerificationFailed(reason)? = snapshot.visibleError else {
            return XCTFail("Expected capture permission verification failure")
        }
        XCTAssertTrue(reason.contains("permissionProbeFailed"))
        XCTAssertTrue(snapshot.canStart)
    }

    func testLateApplicationActivationProbeFailureCannotOverrideExplicitStop() async throws {
        let gate = ProductTestGate()
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        await fixture.audio.setPermissionVerificationGate(gate)
        await fixture.audio.setPermissionVerificationError(
            M1AudioRouteError.audioCapturePermissionDenied
        )
        let activation = Task { await fixture.controller.handleApplicationActivation() }
        await waitUntil { await fixture.audio.permissionVerificationCount == 1 }

        try await fixture.controller.stop()
        await gate.open()
        await activation.value

        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(snapshot.audio, .stopped)
        XCTAssertEqual(snapshot.audioRecovery, .inactive)
        XCTAssertNil(snapshot.visibleError)
    }

    func testPermissionSafetyStopCompletionCannotOverrideNewerExplicitStop() async throws {
        let safetyStopGate = ProductTestGate()
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        await fixture.audio.setPermissionVerificationError(
            M1AudioRouteError.audioCapturePermissionDenied
        )
        await fixture.audio.setStopGates([safetyStopGate])
        let activation = Task { await fixture.controller.handleApplicationActivation() }
        await waitUntil {
            await fixture.audio.calls.filter { $0 == "stop" }.count == 1
        }

        try await fixture.controller.stop()
        await safetyStopGate.open()
        await activation.value

        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(snapshot.audio, .stopped)
        XCTAssertEqual(snapshot.audioRecovery, .inactive)
        XCTAssertNil(snapshot.visibleError)
    }

    func testExplicitStopCancelsRecoveryDuringBackoff() async throws {
        let sleepGate = ProductTestGate()
        let timing = M1AudioRecoveryTiming(
            maximumAttempts: 3,
            delayNanoseconds: { _ in 1 },
            sleep: { _ in await sleepGate.wait() }
        )
        let fixture = makeFixture(recoveryTiming: timing)
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        await fixture.audio.setStartFailuresRemaining(3)
        let recovery = Task {
            await fixture.controller.handleAudioLifecycleEvent(.routeChanged)
        }
        await waitUntil { await fixture.audio.startedConfigurations.count == 2 }

        try await fixture.controller.stop()
        await sleepGate.open()
        await recovery.value

        let snapshot = await fixture.controller.snapshot()
        let starts = await fixture.audio.startedConfigurations
        XCTAssertEqual(snapshot.audio, .stopped)
        XCTAssertEqual(snapshot.audioRecovery, .inactive)
        XCTAssertEqual(starts.count, 2)
    }

    func testRouteEventDuringRecoveryIsCoalescedIntoOneFollowUpRecovery() async throws {
        let fixture = makeFixture(recoveryTiming: immediateRecoveryTiming())
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        let startGate = ProductTestGate()
        await fixture.audio.setStartGate(startGate)
        let firstRecovery = Task {
            await fixture.controller.handleAudioLifecycleEvent(.routeChanged)
        }
        await waitUntil { await fixture.audio.startedConfigurations.count == 2 }

        await fixture.controller.handleAudioLifecycleEvent(.systemAudioServicesChanged)
        await startGate.open()
        await firstRecovery.value
        await waitUntil { await fixture.audio.startedConfigurations.count == 3 }

        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(snapshot.audio, .running)
        XCTAssertEqual(snapshot.audioRecovery, .inactive)
    }

    func testSleepCancelsBlockedExplicitStart() async throws {
        let fixture = makeFixture(recoveryTiming: immediateRecoveryTiming())
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        let startGate = ProductTestGate()
        await fixture.audio.setStartGate(startGate)
        let start = Task { try await fixture.controller.start() }
        await waitUntil { await fixture.audio.startedConfigurations.count == 1 }

        await fixture.controller.handleAudioLifecycleEvent(.willSleep)
        await XCTAssertThrowsErrorAsync { try await start.value }

        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(snapshot.audio, .stopped)
        XCTAssertEqual(snapshot.audioRecovery, .suspendedForSleep)
        XCTAssertFalse(snapshot.canStart)
    }

    func testRouteEventDuringExplicitStartTriggersFollowUpRecovery() async throws {
        let fixture = makeFixture(recoveryTiming: immediateRecoveryTiming())
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        let startGate = ProductTestGate()
        await fixture.audio.setStartGate(startGate)
        let start = Task { try await fixture.controller.start() }
        await waitUntil { await fixture.audio.startedConfigurations.count == 1 }

        await fixture.controller.handleAudioLifecycleEvent(.routeChanged)
        await startGate.open()
        try await start.value
        await waitUntil {
            let starts = await fixture.audio.startedConfigurations.count
            let snapshot = await fixture.controller.snapshot()
            return starts == 2
                && snapshot.audio == .running
                && snapshot.audioRecovery == .inactive
        }

        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(snapshot.audio, .running)
        XCTAssertEqual(snapshot.audioRecovery, .inactive)
    }

    func testStopDuringBlockedOutputLayoutCannotRepublishRunningProjection() async throws {
        let fixture = makeFixture(recoveryTiming: immediateRecoveryTiming())
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        let layoutGate = ProductTestGate()
        await fixture.audio.setLayoutGate(layoutGate)
        let start = Task { try await fixture.controller.start() }
        await waitUntil { await fixture.audio.calls.contains("layout") }

        try await fixture.controller.stop()
        await layoutGate.open()
        await XCTAssertThrowsErrorAsync { try await start.value }

        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(snapshot.audio, .stopped)
        XCTAssertEqual(snapshot.audioRecovery, .inactive)
        XCTAssertNil(snapshot.outputLayout)
    }

    func testCopyIsPureAndFailedCutPreservesDraftAndHistory() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        await fixture.controller.selectNode(fixture.nodeID)
        let pasteboard = ProductPasteboardFake(writeSucceeds: false)
        let before = await fixture.controller.snapshot()

        await XCTAssertThrowsErrorAsync {
            try await fixture.controller.cutSelection(to: pasteboard)
        }

        let afterFailedCut = await fixture.controller.snapshot()
        XCTAssertEqual(afterFailedCut.draft, before.draft)
        XCTAssertFalse(afterFailedCut.canUndo)
        await pasteboard.setWriteSucceeds(true)
        try await fixture.controller.copySelection(to: pasteboard)
        let afterCopy = await fixture.controller.snapshot()
        XCTAssertEqual(afterCopy.draft, before.draft)
        XCTAssertFalse(afterCopy.canUndo)
        let written = await pasteboard.data
        XCTAssertEqual(try M1NodeEnvelopeCodec.decode(XCTUnwrap(written)).nodes.map(\.id), [fixture.nodeID])
    }

    func testPasteUsesTypedEnvelopeAndCreatesNewSelectedIdentity() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        let sourceID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let encoded = try M1NodeEnvelopeCodec.encode([
            M1PreampNode(id: sourceID, isEnabled: false, gainDB: -6, channels: .all)
        ])
        let pasteboard = ProductPasteboardFake(data: encoded.data)

        try await fixture.controller.paste(from: pasteboard)

        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(snapshot.draft.nodes.count, 2)
        XCTAssertEqual(snapshot.draft.nodes.last?.gainDB, -6)
        XCTAssertNotEqual(snapshot.draft.nodes.last?.id, sourceID)
        XCTAssertEqual(snapshot.selectedNodeIDs, Set([snapshot.draft.nodes.last!.id]))
        XCTAssertTrue(snapshot.canUndo)
    }

    func testUnsupportedClipboardVersionIsPasteNoOp() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        let pasteboard = ProductPasteboardFake(
            data: Data("{\"nodes\":[],\"schemaVersion\":5}\n".utf8)
        )
        let before = await fixture.controller.snapshot()

        try await fixture.controller.paste(from: pasteboard)

        let after = await fixture.controller.snapshot()
        XCTAssertEqual(after.draft, before.draft)
        XCTAssertEqual(after.selectedNodeIDs, before.selectedNodeIDs)
        XCTAssertFalse(after.canUndo)
        XCTAssertNil(after.visibleError)
    }

    func testSuccessfulCutWritesBeforeDeletingAndIsOneUndoStep() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        await fixture.controller.selectNode(fixture.nodeID)
        let pasteboard = ProductPasteboardFake()

        try await fixture.controller.cutSelection(to: pasteboard)

        let afterCut = await fixture.controller.snapshot()
        XCTAssertTrue(afterCut.draft.nodes.isEmpty)
        XCTAssertTrue(afterCut.canUndo)
        let pasteboardData = await pasteboard.data
        let written = try XCTUnwrap(pasteboardData)
        XCTAssertEqual(try M1NodeEnvelopeCodec.decode(written).nodes.map(\.id), [fixture.nodeID])
        try await fixture.controller.undo()
        let afterUndo = await fixture.controller.snapshot()
        XCTAssertEqual(afterUndo.draft.nodes.map(\.id), [fixture.nodeID])
    }

    func testTerminationClassifiesNodeEffectsCombinedAndUncertainStates() async throws {
        let nodeFixture = makeFixture()
        await nodeFixture.controller.bootstrap(initialNodeID: nodeFixture.nodeID)
        try await nodeFixture.controller.setGainDB(id: nodeFixture.nodeID, gainDB: 2)
        let nodeTermination = await nodeFixture.controller.requestTermination()
        XCTAssertEqual(nodeTermination, .prompt(.unsavedNodes))

        let effectsFixture = makeFixture()
        await effectsFixture.controller.bootstrap(initialNodeID: effectsFixture.nodeID)
        await effectsFixture.store.setNextResult(.failed(generation: 1, reason: .replaceMain))
        try await effectsFixture.controller.setEffectsEnabled(false)
        let effectsTermination = await effectsFixture.controller.requestTermination()
        XCTAssertEqual(effectsTermination, .prompt(.unsavedEffects))

        try await effectsFixture.controller.setGainDB(id: effectsFixture.nodeID, gainDB: 3)
        let combinedTermination = await effectsFixture.controller.requestTermination()
        XCTAssertEqual(combinedTermination, .prompt(.unsavedNodesAndEffects))

        let uncertainFixture = makeFixture()
        await uncertainFixture.controller.bootstrap(initialNodeID: uncertainFixture.nodeID)
        try await uncertainFixture.controller.setGainDB(id: uncertainFixture.nodeID, gainDB: 4)
        let candidate = await uncertainFixture.controller.snapshot().draft
        await uncertainFixture.store.setNextResult(.uncertain(
            generation: 1,
            snapshot: candidate,
            bootstrapOrigin: nil
        ))
        try await uncertainFixture.controller.save()
        let uncertainTermination = await uncertainFixture.controller.requestTermination()
        XCTAssertEqual(uncertainTermination, .prompt(.uncertainPersistence(generation: 1)))
    }

    func testTerminationCancelReturnsStayOpenWithoutReopeningPrompt() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 2)
        let initial = await fixture.controller.requestTermination()
        XCTAssertEqual(initial, .prompt(.unsavedNodes))

        let cancelled = await fixture.controller.resolveTermination(.cancel)

        guard case .stayOpen = cancelled else { return XCTFail("Expected cancellation") }
        let snapshot = await fixture.controller.snapshot()
        XCTAssertTrue(snapshot.hasUnsavedNodes)
        let calls = await fixture.audio.calls
        XCTAssertFalse(calls.contains("stop"))
    }

    func testSaveAndExitPersistsDraftThenPerformsOrderedShutdown() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.start()
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 5)
        let termination = await fixture.controller.requestTermination()
        XCTAssertEqual(termination, .prompt(.unsavedNodes))

        let decision = await fixture.controller.resolveTermination(.saveAndExit)

        let commits = await fixture.store.commits
        let calls = await fixture.audio.calls
        XCTAssertEqual(decision, .terminate)
        XCTAssertEqual(commits.last?.snapshot.nodes.first?.gainDB, 5)
        XCTAssertEqual(calls.last, "stop")
    }

    func testEffectsRetryFailureKeepsApplicationOpen() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        await fixture.store.setNextResult(.failed(generation: 1, reason: .replaceMain))
        try await fixture.controller.setEffectsEnabled(false)
        await fixture.store.setNextResult(.failed(generation: 2, reason: .replaceMain))

        let decision = await fixture.controller.resolveTermination(.retry)

        guard case .stayOpen = decision else { return XCTFail("Expected termination denial") }
        let calls = await fixture.audio.calls
        XCTAssertFalse(calls.contains("stop"))
    }

    func testTerminationWaitsForInFlightFailureAndDoesNotShutdown() async throws {
        let fixture = makeFixture()
        await fixture.controller.bootstrap(initialNodeID: fixture.nodeID)
        try await fixture.controller.setGainDB(id: fixture.nodeID, gainDB: 2)
        let gate = ProductTestGate()
        await fixture.store.setCommitGate(gate)
        await fixture.store.setNextResult(.failed(generation: 1, reason: .replaceMain))
        let saveTask = Task { try await fixture.controller.save() }
        await waitUntil { await fixture.store.commits.count == 1 }

        let terminationTask = Task { await fixture.controller.requestTermination() }
        await Task.yield()
        let callsBeforeCommit = await fixture.audio.calls
        XCTAssertFalse(callsBeforeCommit.contains("stop"))
        await gate.open()
        try await saveTask.value

        guard case .stayOpen = await terminationTask.value else {
            return XCTFail("Expected failed in-flight Save to deny termination")
        }
        let callsAfterFailure = await fixture.audio.calls
        XCTAssertFalse(callsAfterFailure.contains("stop"))
    }
}

private func productConvolutionIR(storageID: UUID, fileName: String) -> M1ConvolutionIRReference {
    M1ConvolutionIRReference(sourcePath: "/tmp/\(storageID.uuidString)-\(fileName)")
}

private struct ProductFixture {
    let nodeID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let secondNodeID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    let store: ProductStoreFake
    let audio: ProductAudioFake
    let controller: M1ProductController
}

private func makeFixture(
    recoveryTiming: M1AudioRecoveryTiming = .production
) -> ProductFixture {
    let nodeID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let store = ProductStoreFake(bootstrapResult: .loaded(.initial(nodeID: nodeID)))
    let audio = ProductAudioFake()
    return ProductFixture(
        store: store,
        audio: audio,
        controller: M1ProductController(
            store: store,
            audio: audio,
            recoveryTiming: recoveryTiming
        )
    )
}

private func immediateRecoveryTiming(maximumAttempts: Int = 3) -> M1AudioRecoveryTiming {
    M1AudioRecoveryTiming(
        maximumAttempts: maximumAttempts,
        delayNanoseconds: { _ in 0 },
        sleep: { _ in }
    )
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
    private var nextResults: [M1ConfigurationCommitResult] = []
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
        if !nextResults.isEmpty {
            return nextResults.removeFirst()
        }
        return .succeeded(generation: generation, snapshot: candidate.snapshot)
    }

    func retryUncertain(generation: UInt64) -> M1ConfigurationCommitResult {
        retryGenerations.append(generation)
        return retryResult ?? .failed(generation: generation, reason: .persistenceRestricted)
    }

    func setNextResult(_ result: M1ConfigurationCommitResult) { nextResults = [result] }
    func setNextResults(_ results: [M1ConfigurationCommitResult]) { nextResults = results }
    func setRetryResult(_ result: M1ConfigurationCommitResult) { retryResult = result }
    func setCommitGate(_ gate: ProductTestGate?) { commitGate = gate }
    func setBootstrapGate(_ gate: ProductTestGate?) { bootstrapGate = gate }
}

private actor ProductAudioFake: M1ProductAudioControlling {
    var calls: [String] = []
    var startedConfigurations: [M1ConfigurationSnapshot] = []
    var startModes: [M1AudioRouteStartMode] = []
    var formatRecoveryStops: [M1MonitoredOutputIdentity] = []
    var publishedGenerations: [UInt64] = []
    var publishedStagesByChannel: [[[M1CompiledProcessingStage]]] = []
    private var running = false
    private var startCancellationRequested = false
    private var startGate: ProductTestGate?
    private var startFailureState: M1NativeAudioRouteState?
    private var publicationDisposition: M1PreparedPublicationDisposition = .active
    private var publicationGate: ProductTestGate?
    private var publishGate: ProductTestGate?
    private var effectsGate: ProductTestGate?
    private var effectsFailure = false
    private var outputAvailable = true
    private var preparationFails = false
    private var preparationGate: ProductTestGate?
    private var publishFails = false
    private var startFailuresRemaining = 0
    private var permissionFailure = false
    private var permissionVerificationError: (any Error)?
    private var permissionVerificationGate: ProductTestGate?
    private var stopGates: [ProductTestGate] = []
    var permissionVerificationCount = 0
    private var layoutGate: ProductTestGate?
    private var discardedPublicationGenerations: Set<UInt64> = []
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
        try await start(configuration: configuration, mode: .normal)
    }

    func start(configuration: M1ConfigurationSnapshot, mode: M1AudioRouteStartMode) async throws {
        calls.append("start")
        startedConfigurations.append(configuration)
        startModes.append(mode)
        startCancellationRequested = false
        if let startGate { await startGate.wait() }
        if startCancellationRequested { throw CancellationError() }
        if permissionFailure { throw M1AudioRouteError.audioCapturePermissionDenied }
        if startFailuresRemaining > 0 {
            startFailuresRemaining -= 1
            throw ProductAudioFakeError.startFailed
        }
        if startFailureState != nil { throw ProductAudioFakeError.startFailed }
        running = true
    }

    func stop() async {
        calls.append("stop")
        let stopGate = stopGates.isEmpty ? nil : stopGates.removeFirst()
        await stopGate?.wait()
        startCancellationRequested = true
        await startGate?.open()
        running = false
    }

    func stopForOutputFormatRecovery(expectedOutput: M1MonitoredOutputIdentity) async {
        calls.append("stopForFormat")
        formatRecoveryStops.append(expectedOutput)
        startCancellationRequested = true
        await startGate?.open()
        running = false
    }

    func stop(bridgeGeneration: UInt64) async -> Bool {
        guard bridgeGeneration == 1 else { return false }
        await stop()
        return true
    }

    func verifyCapturePermission() async throws -> Bool {
        calls.append("verifyPermission")
        permissionVerificationCount += 1
        await permissionVerificationGate?.wait()
        if let permissionVerificationError { throw permissionVerificationError }
        return true
    }

    func outputLayout() async -> M1OutputLayoutSnapshot? {
        calls.append("layout")
        await layoutGate?.wait()
        return running ? layout : nil
    }

    func discoverOutputLayout() -> M1OutputLayoutSnapshot? {
        outputAvailable ? layout : nil
    }

    func prepare(configuration: M1ConfigurationSnapshot) async throws -> M1AudioConfigurationPreparation {
        calls.append("prepare")
        if let preparationGate { await preparationGate.wait() }
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
        if publishFails { throw ProductAudioFakeError.publishFailed }
        guard preparation.bridgeGeneration == 1, let compiled = preparation.compiled else { return nil }
        publishedGenerations.append(configurationGeneration)
        publishedStagesByChannel.append(compiled.stagesByChannel)
        return M1PreparedPublication(
            disposition: publicationDisposition,
            diagnostics: compiled.diagnostics
        )
    }

    func setEffectsEnabled(_ enabled: Bool) async throws {
        calls.append("effects:\(enabled)")
        await effectsGate?.wait()
        if effectsFailure { throw ProductAudioFakeError.effectsFailed }
    }

    func diagnostics() -> M1RealtimeDiagnostics? {
        guard running else { return nil }
        return M1RealtimeDiagnostics(
            io: M1AudioIOHostCounters(
                capturedFrames: 10,
                renderedFrames: 9,
                overflowedBlocks: 1,
                underrunBlocks: 2,
                droppedBacklogFrames: 3,
                invalidCallbacks: 4,
                overlappingRenderCallbacks: 5
            ),
            runtime: M1RuntimeCounters(
                nonFiniteInputSamples: 6,
                saturatedOutputSamples: 7,
                invalidProcessCalls: 8,
                overlappingCallbacks: 9
            )
        )
    }

    func waitForPublication(configurationGeneration: UInt64) async -> Bool {
        await publicationGate?.wait()
        return publishedGenerations.contains(configurationGeneration)
            && !discardedPublicationGenerations.contains(configurationGeneration)
    }

    func discardPendingPublication() {
        calls.append("discardPending")
        if let generation = publishedGenerations.last {
            discardedPublicationGenerations.insert(generation)
        }
    }

    func setStartGate(_ gate: ProductTestGate?) { startGate = gate }
    func setStartFailure(state: M1NativeAudioRouteState) { startFailureState = state }
    func setOutputAvailable(_ available: Bool) { outputAvailable = available }
    func setPreparationFailure(_ fails: Bool) { preparationFails = fails }
    func setPreparationGate(_ gate: ProductTestGate?) { preparationGate = gate }
    func setPublishFailure(_ fails: Bool) { publishFails = fails }
    func setPublication(disposition: M1PreparedPublicationDisposition, gate: ProductTestGate?) {
        publicationDisposition = disposition
        publicationGate = gate
    }
    func setPublishGate(_ gate: ProductTestGate?) { publishGate = gate }
    func setEffectsGate(_ gate: ProductTestGate?) { effectsGate = gate }
    func setEffectsFailure(_ fails: Bool) { effectsFailure = fails }
    func setStartFailuresRemaining(_ count: Int) { startFailuresRemaining = count }
    func setPermissionFailure(_ fails: Bool) { permissionFailure = fails }
    func setPermissionVerificationError(_ error: (any Error)?) {
        permissionVerificationError = error
    }
    func setPermissionVerificationGate(_ gate: ProductTestGate?) {
        permissionVerificationGate = gate
    }
    func setStopGates(_ gates: [ProductTestGate]) { stopGates = gates }
    func setLayoutGate(_ gate: ProductTestGate?) { layoutGate = gate }
}

private enum ProductAudioFakeError: Error {
    case startFailed
    case preparationFailed
    case publishFailed
    case effectsFailed
    case permissionProbeFailed
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

private actor ProductPasteboardFake: M1PasteboardAccess {
    var data: Data?
    private var writeSucceeds: Bool

    init(data: Data? = nil, writeSucceeds: Bool = true) {
        self.data = data
        self.writeSucceeds = writeSucceeds
    }

    func readNodes() -> Data? { data }

    func writeNodes(_ data: Data) -> Bool {
        guard writeSucceeds else { return false }
        self.data = data
        return true
    }

    func setWriteSucceeds(_ succeeds: Bool) { writeSucceeds = succeeds }
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
