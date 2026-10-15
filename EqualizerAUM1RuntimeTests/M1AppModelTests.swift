import Foundation
import XCTest

@MainActor
final class M1AppModelTests: XCTestCase {
    func testBootstrapIsIdempotentAndStartsMonitorOnce() async {
        let fixture = makeAppModelFixture()

        fixture.model.bootstrap()
        fixture.model.bootstrap()
        await fixture.model.waitUntilIdle()

        let bootstrapCount = await fixture.store.observedBootstrapCount()
        XCTAssertEqual(bootstrapCount, 1)
        XCTAssertEqual(fixture.monitor.observedStartCount(), 1)
        fixture.monitor.emit(.monitoringFailed)
        for _ in 0..<100 where fixture.model.snapshot.visibleError == nil {
            await Task.yield()
        }
        XCTAssertNotNil(fixture.model.snapshot.visibleError)
        XCTAssertTrue(fixture.model.snapshot.canEdit)
    }

    func testEditingCommandsUpdateDraftAndHistory() async throws {
        let fixture = makeAppModelFixture()
        fixture.model.bootstrap()
        await fixture.model.waitUntilIdle()
        let initialID = try XCTUnwrap(fixture.model.snapshot.draft.nodes.first?.id)

        fixture.model.select(initialID, mode: .replacing)
        fixture.model.add(before: nil)
        fixture.model.addChannels(before: nil)
        fixture.model.addGraphicEQ(before: nil)
        fixture.model.addFilter(before: nil)
        fixture.model.addDelay(before: nil)
        fixture.model.addLoudness(before: nil)
        fixture.model.importConvolution(before: nil)
        await fixture.model.waitUntilIdle()

        let nodes = fixture.model.snapshot.draft.nodes
        XCTAssertEqual(nodes.count, 8)
        let preamp = try XCTUnwrap(nodes.first { $0.kind == .preamp })
        let channels = try XCTUnwrap(nodes.first { $0.kind == .channels })
        let graphicEQ = try XCTUnwrap(nodes.first { $0.kind == .graphicEQ })
        let filter = try XCTUnwrap(nodes.first { $0.kind == .filter })
        let convolution = try XCTUnwrap(nodes.first { $0.kind == .convolution })

        fixture.model.setGain(-6, id: preamp.id)
        fixture.model.setEnabled(false, id: preamp.id)
        fixture.model.setChannels(.all, id: channels.id)
        fixture.model.setGraphicEQPoints([
            M1GraphicEQPoint(frequencyHz: 1_000, gainDB: 2),
        ], id: graphicEQ.id)
        fixture.model.setFilterSpecification(
            M1FilterSpecification(
                type: .lowShelf,
                frequencyHz: 120,
                gainDB: 6,
                width: .slopeDBPerOctave(12),
                cornerFrequency: true
            ),
            id: filter.id
        )
        let delay = try XCTUnwrap(nodes.first { $0.kind == .delay })
        let loudness = try XCTUnwrap(nodes.first { $0.kind == .loudness })
        fixture.model.setDelaySpecification(
            M1DelaySpecification(value: 5, unit: .samples),
            id: delay.id
        )
        fixture.model.setLoudnessSpecification(
            M1LoudnessSpecification(referenceVolumeDB: -25, strength: 0.5),
            id: loudness.id
        )
        fixture.model.replaceConvolutionIR(id: convolution.id)
        fixture.model.beginGesture(preamp.id)
        fixture.model.endGesture(preamp.id)
        await fixture.model.waitUntilIdle()

        XCTAssertTrue(fixture.model.snapshot.hasUnsavedNodes)
        XCTAssertTrue(fixture.model.snapshot.canUndo)
        XCTAssertEqual(
            try XCTUnwrap(fixture.model.snapshot.draft.nodes.first { $0.id == filter.id })
                .filterSpecification,
            M1FilterSpecification(
                type: .lowShelf,
                frequencyHz: 120,
                gainDB: 6,
                width: .slopeDBPerOctave(12),
                cornerFrequency: true
            )
        )
        fixture.model.undo()
        await fixture.model.waitUntilIdle()
        fixture.model.redo()
        await fixture.model.waitUntilIdle()
        XCTAssertTrue(fixture.model.snapshot.canUndo)
    }

    func testSelectionClipboardDragAndDeleteCommands() async throws {
        let fixture = makeAppModelFixture()
        fixture.model.bootstrap()
        await fixture.model.waitUntilIdle()
        let initialID = try XCTUnwrap(fixture.model.snapshot.draft.nodes.first?.id)

        fixture.model.select(initialID, mode: .replacing)
        await fixture.model.waitUntilIdle()
        fixture.model.copy()
        await fixture.model.waitUntilIdle()
        let pasteboardData = await fixture.pasteboard.readNodes()
        XCTAssertNotNil(pasteboardData)

        fixture.model.paste()
        await fixture.model.waitUntilIdle()
        XCTAssertEqual(fixture.model.snapshot.draft.nodes.count, 2)

        let draggedID = try XCTUnwrap(fixture.model.snapshot.selectedNodeIDs.first)
        _ = fixture.model.beginDrag(draggedID)
        fixture.model.moveDraggedSelection(to: 0, operation: .copy)
        await fixture.model.waitUntilIdle()
        XCTAssertEqual(fixture.model.snapshot.draft.nodes.count, 3)

        fixture.model.selectAll()
        await fixture.model.waitUntilIdle()
        fixture.model.moveSelection(by: -1)
        fixture.model.deleteSelection()
        await fixture.model.waitUntilIdle()
        XCTAssertTrue(fixture.model.snapshot.draft.nodes.isEmpty)
    }

    func testImportEqualizerAPOConfigurationParksAppliesAndCancels() async throws {
        let fixture = makeAppModelFixture()
        fixture.model.bootstrap()
        await fixture.model.waitUntilIdle()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m14-model-\(UUID().uuidString).txt")
        try "Preamp: -3 dB\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        fixture.model.importEqualizerAPOConfiguration(from: url)
        await fixture.model.waitUntilIdle()
        var snapshot = fixture.model.snapshot
        XCTAssertEqual(snapshot.pendingImport?.nodes.map(\.kind), [.preamp])

        fixture.model.cancelImport()
        await fixture.model.waitUntilIdle()
        snapshot = fixture.model.snapshot
        XCTAssertNil(snapshot.pendingImport)
        XCTAssertEqual(snapshot.draft.nodes.count, 1)
        XCTAssertEqual(snapshot.persistence, .clean)

        fixture.model.importEqualizerAPOConfiguration(from: url)
        await fixture.model.waitUntilIdle()
        fixture.model.applyImport(.replaceExisting)
        await fixture.model.waitUntilIdle()
        snapshot = fixture.model.snapshot
        XCTAssertNil(snapshot.pendingImport)
        XCTAssertEqual(snapshot.draft.nodes.count, 1)
        XCTAssertEqual(snapshot.draft.nodes[0].gainDB, -3)
        XCTAssertEqual(snapshot.persistence, .modified)
    }

    func testPasteGraphicEQTextCreatesSelectedGraphicEQNode() async throws {
        let fixture = makeAppModelFixture()
        fixture.model.bootstrap()
        await fixture.model.waitUntilIdle()
        fixture.pasteboard.setText("GraphicEQ: 100 -3,5; 200 -2")

        fixture.model.paste()
        await fixture.model.waitUntilIdle()

        let snapshot = fixture.model.snapshot
        XCTAssertEqual(snapshot.draft.nodes.count, 2)
        let pasted = try XCTUnwrap(snapshot.draft.nodes.last)
        XCTAssertEqual(pasted.kind, .graphicEQ)
        XCTAssertTrue(pasted.isEnabled)
        XCTAssertEqual(pasted.graphicEQPoints, [
            M1GraphicEQPoint(frequencyHz: 100, gainDB: -3.5),
            M1GraphicEQPoint(frequencyHz: 200, gainDB: -2),
        ])
        XCTAssertEqual(snapshot.selectedNodeIDs, Set([pasted.id]))
        XCTAssertNil(snapshot.visibleError)
    }

    func testSaveStartProcessingDiagnosticsAndStop() async {
        let fixture = makeAppModelFixture()
        fixture.model.bootstrap()
        await fixture.model.waitUntilIdle()

        fixture.model.save()
        await fixture.model.waitUntilIdle()
        fixture.model.start()
        await fixture.model.waitUntilIdle()
        XCTAssertEqual(fixture.model.snapshot.audio, .running)

        fixture.model.setProcessing(false)
        await fixture.model.waitUntilIdle()
        fixture.model.refreshDiagnostics()
        await fixture.model.waitUntilIdle()
        fixture.model.presentDiagnostics()
        await fixture.model.waitUntilIdle()
        XCTAssertEqual(fixture.presentedDiagnostics.count, 1)
        XCTAssertTrue(fixture.presentedDiagnostics[0].contains("Captured frames: 10"))

        fixture.model.stop()
        await fixture.model.waitUntilIdle()
        XCTAssertEqual(fixture.model.snapshot.audio, .stopped)
    }

    func testApplicationActivationRetryAndTerminationStopMonitor() async throws {
        let fixture = makeAppModelFixture()
        fixture.model.bootstrap()
        await fixture.model.waitUntilIdle()

        fixture.model.start()
        await fixture.model.waitUntilIdle()
        fixture.model.applicationDidBecomeActive()
        await fixture.model.handleAudioLifecycleEvent(.monitoringFailed)
        fixture.model.retryOutput()
        await fixture.model.waitUntilIdle()
        let calls = await fixture.audio.observedCalls()
        XCTAssertTrue(calls.contains("verifyPermission"))

        fixture.model.add(before: nil)
        await fixture.model.waitUntilIdle()
        let firstDecision = await fixture.model.requestTermination()
        XCTAssertEqual(firstDecision, .prompt(.unsavedNodes))
        let finalDecision = await fixture.model.resolveTermination(.discardAndExit)
        XCTAssertEqual(finalDecision, .terminate)
        XCTAssertEqual(fixture.monitor.observedStopCount(), 1)
    }

    func testAdditionalEditEffectsRetryAndShutdownCommands() async throws {
        let fixture = makeAppModelFixture()
        fixture.model.bootstrap()
        await fixture.model.waitUntilIdle()
        let initialID = try XCTUnwrap(fixture.model.snapshot.draft.nodes.first?.id)

        fixture.model.add(before: nil)
        await fixture.model.waitUntilIdle()
        fixture.model.move(initialID, to: 1)
        fixture.model.select(initialID, mode: .replacing)
        await fixture.model.waitUntilIdle()
        fixture.model.moveFocus(by: -1, extending: false)
        fixture.model.selectFocused(toggling: true)
        fixture.model.beginDrag(initialID)
        fixture.model.cancelDrag()
        fixture.model.cut()
        await fixture.model.waitUntilIdle()

        fixture.model.setEffects(false)
        fixture.model.retryPersistence()
        await fixture.model.waitUntilIdle()
        try await fixture.model.shutdown()
        XCTAssertEqual(fixture.monitor.observedStopCount(), 1)
    }

    func testEditFailureIsPresentedBeforeTerminationDecision() async {
        let fixture = makeAppModelFixture()
        fixture.model.bootstrap()
        await fixture.model.waitUntilIdle()

        fixture.model.delete(UUID())
        await fixture.model.waitUntilIdle()
        let decision = await fixture.model.requestTermination()
        guard case let .stayOpen(message) = decision else {
            return XCTFail("failed editor command must keep the app open")
        }
        guard case .technical = message else {
            return XCTFail("failed editor command must expose the technical error")
        }
    }

    func testPresentationMessagesAndLanguagesHaveStableLocalizedValues() {
        let locale = Locale(identifier: "en")
        let messages: [M1PresentationMessage] = [
            .audioCapturePermissionRequired,
            .audioStoppedAfterRetirementMaintenance("maintenance"),
            .audioDeviceMonitoringUnavailable,
            .capturePermissionVerificationFailed("verify"),
            .capturePermissionCleanupFailed("cleanup"),
            .automaticAudioRecoveryPaused("paused"),
            .configurationDurabilityUncertain,
            .editorChangeCouldNotApply,
            .configurationRepairFailed,
            .pastedGraphicEQPointLimitExceeded(count: 3, maximum: 1),
            .terminationCancelled,
            .technical("detail"),
        ]
        for message in messages {
            _ = message.localizedKey
            XCTAssertFalse(message.localizedString(locale: locale).isEmpty)
        }
        for language in M1ApplicationLanguage.allCases {
            _ = language.titleKey
        }
        XCTAssertEqual(M1ApplicationLanguage.english.locale.identifier, "en")
        XCTAssertEqual(M1RuntimeBootstrap.abiVersion, EAUM1_RUNTIME_ABI_VERSION)
    }
}

@MainActor
private final class AppModelFixture {
    let store: AppModelStoreFake
    let audio: AppModelAudioFake
    let pasteboard: AppModelPasteboardFake
    let monitor: AppModelMonitorFake
    var presentedDiagnostics: [String] = []
    lazy var model = M1AppModel(
        controller: M1ProductController(store: store, audio: audio),
        pasteboard: pasteboard,
        audioLifecycleMonitor: monitor,
        wavPicker: { URL(fileURLWithPath: "/tmp/test-ir.wav") },
        diagnosticsPresenter: { [weak self] text in self?.presentedDiagnostics.append(text) },
        textCommandRouter: AppModelTextCommandRouterFake()
    )

    init() {
        let nodeID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        store = AppModelStoreFake(snapshot: .initial(nodeID: nodeID))
        audio = AppModelAudioFake()
        pasteboard = AppModelPasteboardFake()
        monitor = AppModelMonitorFake()
    }
}

@MainActor
private func makeAppModelFixture() -> AppModelFixture { AppModelFixture() }

private actor AppModelStoreFake: M1ConfigurationStoring {
    let snapshot: M1ConfigurationSnapshot
    var bootstrapCount = 0

    init(snapshot: M1ConfigurationSnapshot) { self.snapshot = snapshot }

    func observedBootstrapCount() -> Int { bootstrapCount }

    func bootstrap(initialNodeID: UUID) -> M1ConfigurationBootstrapResult {
        bootstrapCount += 1
        return .loaded(snapshot)
    }

    func commit(
        _ candidate: M1EncodedConfiguration,
        generation: UInt64,
        mode: M1ConfigurationCommitMode
    ) -> M1ConfigurationCommitResult {
        .succeeded(generation: generation, snapshot: candidate.snapshot)
    }

    func retryUncertain(generation: UInt64) -> M1ConfigurationCommitResult {
        .failed(generation: generation, reason: .persistenceRestricted)
    }
}

private actor AppModelAudioFake: M1ProductAudioControlling {
    var calls: [String] = []
    private var running = false
    private let layout = M1OutputLayoutSnapshot(
        sampleRate: 48_000,
        maximumFrameCount: 256,
        bufferChannelCounts: [2],
        semanticPositionsByChannelIndex: [.left, .right]
    )!

    func observedCalls() -> [String] { calls }

    func state() -> M1NativeAudioRouteState {
        running ? .running(generation: .init(rawValue: 1), bridgeGeneration: 1) : .stopped
    }

    func start(configuration: M1ConfigurationSnapshot) {
        calls.append("start")
        running = true
    }

    func stop() {
        calls.append("stop")
        running = false
    }

    func stop(bridgeGeneration: UInt64) -> Bool {
        guard bridgeGeneration == 1 else { return false }
        running = false
        return true
    }

    func verifyCapturePermission() -> Bool {
        calls.append("verifyPermission")
        return true
    }

    func outputLayout() -> M1OutputLayoutSnapshot? { running ? layout : nil }
    func discoverOutputLayout() -> M1OutputLayoutSnapshot? { layout }

    func prepare(configuration: M1ConfigurationSnapshot) throws -> M1AudioConfigurationPreparation {
        calls.append("prepare")
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
    ) -> M1PreparedPublication? {
        guard preparation.bridgeGeneration == 1, let compiled = preparation.compiled else { return nil }
        return M1PreparedPublication(disposition: .active, diagnostics: compiled.diagnostics)
    }

    func waitForPublication(configurationGeneration: UInt64) -> Bool { true }
    func discardPendingPublication() {}

    func setEffectsEnabled(_ enabled: Bool) {
        calls.append("effects:\(enabled)")
    }

    func activateEffects(
        preparation: M1AudioConfigurationPreparation,
        activationToken: M1EffectsActivationToken
    ) -> M1ProcessingBuildDiagnostics? {
        preparation.compiled?.diagnostics
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
}

private final class AppModelPasteboardFake: M1PasteboardAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var text: String?

    func readNodes() -> Data? {
        lock.withLock { data }
    }

    func writeNodes(_ data: Data) -> Bool {
        lock.withLock { self.data = data }
        return true
    }

    func readText() -> String? {
        lock.withLock { text }
    }

    func setText(_ newText: String?) {
        lock.withLock { text = newText }
    }
}

@MainActor
private struct AppModelTextCommandRouterFake: M1TextCommandRouting {
    func route(_ selector: Selector) -> Bool { false }
    func routeHistory(redo: Bool) -> Bool { false }
    func handleSpace(toggling: Bool) -> Bool { false }
}

private final class AppModelMonitorFake: M1AudioLifecycleMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var startCount = 0
    private var stopCount = 0
    private var handler: (@Sendable (M1AudioLifecycleEvent) -> Void)?

    func start(handler: @escaping @Sendable (M1AudioLifecycleEvent) -> Void) {
        lock.withLock {
            startCount += 1
            self.handler = handler
        }
    }

    func stop() {
        lock.withLock { stopCount += 1 }
    }

    func emit(_ event: M1AudioLifecycleEvent) {
        lock.withLock { handler }?(event)
    }

    func observedStartCount() -> Int { lock.withLock { startCount } }
    func observedStopCount() -> Int { lock.withLock { stopCount } }
}
