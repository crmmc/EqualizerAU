import Foundation

enum M1ApplicationLanguage: String, CaseIterable, Sendable {
    case system
    case english
    case simplifiedChinese

    static let defaultsKey = "applicationLanguage"

    var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .english: Locale(identifier: "en")
        case .simplifiedChinese: Locale(identifier: "zh-Hans")
        }
    }
}

protocol M1ConfigurationStoring: Sendable {
    func bootstrap(initialNodeID: UUID) async -> M1ConfigurationBootstrapResult
    func commit(
        _ candidate: M1EncodedConfiguration,
        generation: UInt64,
        mode: M1ConfigurationCommitMode
    ) async -> M1ConfigurationCommitResult
    func retryUncertain(generation: UInt64) async -> M1ConfigurationCommitResult
}

extension M1ConfigurationStore: M1ConfigurationStoring {}

final class M1EffectsActivationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true

    var isCurrent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func invalidate() {
        lock.lock()
        current = false
        lock.unlock()
    }

    func performIfCurrent<Result>(_ operation: () throws -> Result) rethrows -> Result? {
        lock.lock()
        defer { lock.unlock() }
        guard current else { return nil }
        return try operation()
    }
}

protocol M1ProductAudioControlling: Sendable {
    func state() async -> M1NativeAudioRouteState
    func start(configuration: M1ConfigurationSnapshot) async throws
    func start(configuration: M1ConfigurationSnapshot, mode: M1AudioRouteStartMode) async throws
    func stop() async throws
    func stopForOutputFormatRecovery(expectedOutput: M1MonitoredOutputIdentity) async throws
    func stop(bridgeGeneration: UInt64) async throws -> Bool
    func verifyCapturePermission() async throws -> Bool
    func outputLayout() async -> M1OutputLayoutSnapshot?
    func discoverOutputLayout() async -> M1OutputLayoutSnapshot?
    func prepare(configuration: M1ConfigurationSnapshot) async throws -> M1AudioConfigurationPreparation
    func publish(
        preparation: M1AudioConfigurationPreparation,
        configurationGeneration: UInt64
    ) async throws -> M1PreparedPublication?
    func waitForPublication(configurationGeneration: UInt64) async -> Bool
    func discardPendingPublication() async
    func setEffectsEnabled(_ enabled: Bool) async throws
    func activateEffects(
        preparation: M1AudioConfigurationPreparation,
        activationToken: M1EffectsActivationToken
    ) async throws -> M1ProcessingBuildDiagnostics?
    func diagnostics() async throws -> M1RealtimeDiagnostics?
    func processingDiagnostics() async -> M1ProcessingBuildDiagnostics?
}

extension M1ProductAudioControlling {
    func start(configuration: M1ConfigurationSnapshot, mode: M1AudioRouteStartMode) async throws {
        try await start(configuration: configuration)
    }

    func stopForOutputFormatRecovery(expectedOutput: M1MonitoredOutputIdentity) async throws {
        try await stop()
    }

    func verifyCapturePermission() async throws -> Bool { false }
    func discoverOutputLayout() async -> M1OutputLayoutSnapshot? { await outputLayout() }
    func processingDiagnostics() async -> M1ProcessingBuildDiagnostics? { nil }
}

extension M1NativeAudioRouteCoordinator: M1ProductAudioControlling {}

enum M1AudioLifecycleEvent: Equatable, Sendable {
    case routeChanged
    case outputFormatChanged(M1MonitoredOutputIdentity)
    case systemAudioServicesChanged
    case monitoringFailed
    case willSleep
    case didWake
}

enum M1AudioDevicePropertyChange: Hashable, Sendable {
    case alive
    case outputFormat
}

enum M1AudioDevicePropertyEventClassifier {
    static func event(
        for changes: Set<M1AudioDevicePropertyChange>,
        output: M1MonitoredOutputIdentity?
    ) -> M1AudioLifecycleEvent? {
        if changes.contains(.alive) {
            return .routeChanged
        }
        if changes.contains(.outputFormat) {
            return output.map(M1AudioLifecycleEvent.outputFormatChanged) ?? .routeChanged
        }
        return nil
    }
}

struct M1MonitoredOutputIdentity: Equatable, Sendable {
    let objectID: UInt32
    let persistentUID: String
}

enum M1AudioSystemPropertyChange: Hashable, Sendable {
    case defaultOutput
    case deviceList
}

enum M1AudioLifecycleEventClassifier {
    static func event(
        for changes: Set<M1AudioSystemPropertyChange>,
        previousOutput: M1MonitoredOutputIdentity?,
        currentOutput: M1MonitoredOutputIdentity?
    ) -> M1AudioLifecycleEvent? {
        if changes.contains(.defaultOutput) {
            return .routeChanged
        }
        if changes.contains(.deviceList), previousOutput != currentOutput {
            return .systemAudioServicesChanged
        }
        return nil
    }
}

struct M1AudioDeviceListChangeTracker: Sendable {
    private var previousOutput: M1MonitoredOutputIdentity?
    private var isPending = false

    mutating func begin(previousOutput: M1MonitoredOutputIdentity?) {
        self.previousOutput = previousOutput
        isPending = true
    }

    mutating func finish(
        currentOutput: M1MonitoredOutputIdentity?
    ) -> M1AudioLifecycleEvent? {
        guard isPending else { return nil }
        let previousOutput = previousOutput
        cancel()
        return M1AudioLifecycleEventClassifier.event(
            for: [.deviceList],
            previousOutput: previousOutput,
            currentOutput: currentOutput
        )
    }

    mutating func cancel() {
        previousOutput = nil
        isPending = false
    }
}

enum M1AudioRecoveryReason: Equatable, Sendable {
    case routeChanged
    case outputFormatChanged(M1MonitoredOutputIdentity)
    case systemAudioServicesChanged
    case wake

    var isOutputFormatChange: Bool {
        if case .outputFormatChanged = self { return true }
        return false
    }
}

enum M1AudioRecoveryState: Equatable, Sendable {
    case inactive
    case suspendedForSleep
    case recovering(reason: M1AudioRecoveryReason, attempt: Int, maximumAttempts: Int)
    case waitingForRetry(reason: M1AudioRecoveryReason)
    case permissionRequired
}

struct M1AudioRecoveryTiming: Sendable {
    let maximumAttempts: Int
    let delayNanoseconds: @Sendable (_ completedAttempt: Int) -> UInt64
    let sleep: @Sendable (_ nanoseconds: UInt64) async throws -> Void

    static let production = M1AudioRecoveryTiming(
        maximumAttempts: 3,
        delayNanoseconds: { attempt in
            attempt == 1 ? 250_000_000 : 1_000_000_000
        },
        sleep: { try await Task.sleep(nanoseconds: $0) }
    )
}

enum M1PresentationMessage: Equatable, Sendable {
    case audioCapturePermissionRequired
    case audioStoppedAfterRetirementMaintenance(String)
    case audioDeviceMonitoringUnavailable
    case capturePermissionVerificationFailed(String)
    case capturePermissionCleanupFailed(String)
    case automaticAudioRecoveryPaused(String)
    case configurationDurabilityUncertain
    case editorChangeCouldNotApply
    case configurationRepairFailed
    case terminationCancelled
    case technical(String)
}

enum M1ProductPersistenceState: Equatable, Sendable {
    case clean
    case modified
    case saving(generation: UInt64)
    case uncertain(generation: UInt64)
    case recovery
    case waitingForOutput
    case savedPendingStart
    case pendingApplication(generation: UInt64)
    case failed(String)
}

enum M1ProductAudioState: Equatable, Sendable {
    case stopped
    case starting
    case running
    case stopping
    case cleanupRequired
}

enum M1ProcessingTransition: Equatable, Sendable {
    case idle
    case fadingOut
    case preparing
    case fadingIn
}

struct M1ProductSnapshot: Equatable, Sendable {
    let draft: M1ConfigurationSnapshot
    let selectedNodeIDs: Set<UUID>
    let focusedNodeID: UUID?
    let persistence: M1ProductPersistenceState
    let audio: M1ProductAudioState
    let audioRecovery: M1AudioRecoveryState
    let outputLayout: M1OutputLayoutSnapshot?
    let availableOutputLayout: M1OutputLayoutSnapshot?
    let activeDiagnostics: M1ProcessingBuildDiagnostics?
    let expectedDiagnostics: M1ProcessingBuildDiagnostics?
    let activeConfigurationGeneration: UInt64?
    let expectedConfigurationGeneration: UInt64?
    let realtimeDiagnostics: M1RealtimeDiagnostics?
    let requestedEffectsEnabled: Bool
    let appliedEffectsEnabled: Bool?
    let processingTransition: M1ProcessingTransition
    let canEdit: Bool
    let canSetEffects: Bool
    let canSave: Bool
    let canStart: Bool
    let canStop: Bool
    let canUndo: Bool
    let canRedo: Bool
    let canUseSelection: Bool
    let hasUnsavedNodes: Bool
    let hasUnsavedEffects: Bool
    let visibleError: M1PresentationMessage?

    var processingEnabled: Bool {
        audio == .running
            && appliedEffectsEnabled == true
            && processingTransition == .idle
    }

    var processingRequested: Bool {
        switch audio {
        case .running, .starting, .stopping:
            return requestedEffectsEnabled
        case .stopped, .cleanupRequired:
            switch audioRecovery {
            case .suspendedForSleep, .recovering:
                return requestedEffectsEnabled
            case .inactive, .waitingForRetry, .permissionRequired:
                return false
            }
        }
    }

    var canSetProcessing: Bool {
        if audio == .running { return canSetEffects }
        return audio == .stopped && canStart
    }
}

enum M1TerminationPrompt: Equatable, Sendable {
    case unsavedNodes
    case unsavedEffects
    case unsavedNodesAndEffects
    case uncertainPersistence(generation: UInt64)
}

enum M1TerminationDecision: Equatable, Sendable {
    case terminate
    case prompt(M1TerminationPrompt)
    case stayOpen(M1PresentationMessage)
}

enum M1TerminationAction: Sendable {
    case saveAndExit
    case discardAndExit
    case retry
    case exit
    case cancel
}

@MainActor
final class M1PendingEditorCommitCoordinator {
    private var registration: (id: UUID, commit: () -> Void)?

    @discardableResult
    func register(_ commit: @escaping () -> Void) -> UUID {
        let id = UUID()
        registration = (id, commit)
        return id
    }

    func unregister(_ id: UUID) {
        if registration?.id == id { registration = nil }
    }

    func commitPendingEditor() {
        registration?.commit()
    }
}

enum M1ProductControllerError: Error, Equatable, Sendable {
    case notBootstrapped
    case commandUnavailable
    case nodeNotFound
    case generationExhausted
}

actor M1ProductController {
    private struct EffectsIntent: Sendable {
        let id: UInt64
        let enabled: Bool
    }

    private struct PendingApplication: Sendable {
        let generation: UInt64
        let snapshot: M1ConfigurationSnapshot
        let preparation: M1AudioConfigurationPreparation
    }

    private let store: any M1ConfigurationStoring
    private let audio: any M1ProductAudioControlling
    private let recoveryTiming: M1AudioRecoveryTiming
    private var draft = M1ConfigurationSnapshot.transparentRecovery
    private var saved = M1ConfigurationSnapshot.transparentRecovery
    private var runtimeBaseline = M1ConfigurationSnapshot.transparentRecovery
    private var editingSession = M1EditingSession(nodes: [])
    private var persistence: M1ProductPersistenceState = .recovery
    private var audioState: M1ProductAudioState = .stopped
    private var audioRecovery: M1AudioRecoveryState = .inactive
    private var layout: M1OutputLayoutSnapshot?
    private var availableLayout: M1OutputLayoutSnapshot?
    private var activeDiagnostics: M1ProcessingBuildDiagnostics?
    private var expectedDiagnostics: M1ProcessingBuildDiagnostics?
    private var activeConfigurationGeneration: UInt64?
    private var expectedConfigurationGeneration: UInt64?
    private var realtimeDiagnostics: M1RealtimeDiagnostics?
    private var requestedEffectsEnabled = M1ConfigurationSnapshot.transparentRecovery.effectsEnabled
    private var appliedEffectsEnabled: Bool?
    private var processingTransition: M1ProcessingTransition = .idle
    private var visibleError: M1PresentationMessage?
    private var effectsOperationError: M1PresentationMessage?
    private var commitGeneration: UInt64 = 0
    private var draftRevision: UInt64 = 0
    private var bootstrapped = false
    private var bootstrapInProgress = false
    private var persistenceInFlight = false
    private var acceptedOperations = 0
    private var effectsUpdateInFlight = false
    private var nextEffectsOperationID: UInt64 = 0
    private var activeEffectsOperationID: UInt64?
    private var activeEffectsActivationToken: M1EffectsActivationToken?
    private var pendingEffectsIntent: EffectsIntent?
    private var pendingEffectsEnabled: Bool?
    private var persistingEffectsEnabled: Bool?
    private var uncertainApplication: PendingApplication?
    private var pendingApplication: PendingApplication?
    private var publicationTask: Task<Void, Never>?
    private var terminating = false
    private var requiresRepair = false
    private var automaticRecoveryDesired = false
    private var recoveryInProgress = false
    private var recoveryToken: UInt64 = 0
    private var isSystemSleeping = false
    private var pendingRecoveryReason: M1AudioRecoveryReason?

    init(
        store: any M1ConfigurationStoring,
        audio: any M1ProductAudioControlling,
        recoveryTiming: M1AudioRecoveryTiming = .production
    ) {
        self.store = store
        self.audio = audio
        self.recoveryTiming = recoveryTiming
    }

    func bootstrap(initialNodeID: UUID = UUID()) async {
        if bootstrapped || terminating { return }
        while bootstrapInProgress {
            await Task.yield()
            if bootstrapped || terminating { return }
        }
        bootstrapInProgress = true
        acceptedOperations += 1
        defer {
            acceptedOperations -= 1
            bootstrapInProgress = false
        }
        let result = await store.bootstrap(initialNodeID: initialNodeID)
        switch result {
        case let .loaded(snapshot), let .recoveredFromPrevious(snapshot):
            draft = snapshot
            saved = snapshot
            runtimeBaseline = snapshot
            persistence = .clean
        case let .recovery(editable, runtime, reason):
            draft = editable
            saved = editable
            runtimeBaseline = runtime
            persistence = .recovery
            requiresRepair = true
            visibleError = .technical(String(describing: reason))
        case let .uncertain(generation, snapshot, _):
            draft = snapshot
            saved = snapshot
            runtimeBaseline = snapshot
            commitGeneration = generation
            persistence = .uncertain(generation: generation)
        }
        editingSession = M1EditingSession(nodes: draft.nodes)
        requestedEffectsEnabled = draft.effectsEnabled
        availableLayout = await audio.discoverOutputLayout()
        bootstrapped = true
    }

    func snapshot() -> M1ProductSnapshot {
        let uncertain: Bool
        if case .uncertain = persistence { uncertain = true } else { uncertain = false }
        let recovery: Bool
        if case .recovery = persistence { recovery = true } else { recovery = false }
        let waitingForOutput: Bool
        if case .waitingForOutput = persistence { waitingForOutput = true } else { waitingForOutput = false }
        return M1ProductSnapshot(
            draft: draft,
            selectedNodeIDs: editingSession.selectedNodeIDs,
            focusedNodeID: editingSession.focusedNodeID,
            persistence: persistence,
            audio: audioState,
            audioRecovery: audioRecovery,
            outputLayout: layout,
            availableOutputLayout: availableLayout,
            activeDiagnostics: activeDiagnostics,
            expectedDiagnostics: expectedDiagnostics,
            activeConfigurationGeneration: activeConfigurationGeneration,
            expectedConfigurationGeneration: expectedConfigurationGeneration,
            realtimeDiagnostics: realtimeDiagnostics,
            requestedEffectsEnabled: requestedEffectsEnabled,
            appliedEffectsEnabled: appliedEffectsEnabled,
            processingTransition: processingTransition,
            canEdit: bootstrapped && !uncertain && !terminating,
            canSetEffects: bootstrapped && !uncertain && !recovery && !terminating
                && (audioState == .stopped || audioState == .running),
            canSave: bootstrapped && !uncertain && !persistenceInFlight && !effectsUpdateInFlight
                && !terminating && (audioState == .stopped || audioState == .running)
                && (recovery || waitingForOutput || draft != saved),
            canStart: bootstrapped && !uncertain && !persistenceInFlight && !effectsUpdateInFlight
                && !terminating && !isSystemSleeping && audioState == .stopped && !recoveryInProgress,
            canStop: audioState != .stopped,
            canUndo: bootstrapped && !uncertain && !terminating && editingSession.canUndo,
            canRedo: bootstrapped && !uncertain && !terminating && editingSession.canRedo,
            canUseSelection: bootstrapped && !uncertain && !terminating
                && !editingSession.selectedNodeIDs.isEmpty,
            hasUnsavedNodes: requiresRepair || draft.nodes != saved.nodes,
            hasUnsavedEffects: draft.effectsEnabled != saved.effectsEnabled,
            visibleError: visibleError
        )
    }

    func selectNode(_ id: UUID?, mode: M1SelectionMode = .replacing) {
        guard snapshot().canEdit else { return }
        editingSession.select(id, mode: mode)
    }

    func selectAllNodes() {
        guard snapshot().canEdit else { return }
        editingSession.selectAll()
    }

    func replaceSelection(_ ids: Set<UUID>) {
        guard snapshot().canEdit else { return }
        editingSession.replaceSelection(ids)
    }

    func moveSelectionFocus(by offset: Int, extending: Bool) {
        guard snapshot().canEdit else { return }
        editingSession.moveFocus(by: offset, extending: extending)
    }

    func selectFocusedNode(toggling: Bool) {
        guard snapshot().canEdit else { return }
        editingSession.selectFocused(toggling: toggling)
    }

    func beginEditGesture(_ id: UUID) {
        editingSession.beginGesture(id)
    }

    func endEditGesture(_ id: UUID) {
        editingSession.endGesture(id)
    }

    func addPreamp(before id: UUID? = nil, nodeID: UUID = UUID()) async throws {
        try await updateEditingSession { session, effectsEnabled in
            try session.addPreamp(before: id, nodeID: nodeID, effectsEnabled: effectsEnabled)
        }
    }

    func addChannels(
        before id: UUID? = nil,
        nodeID: UUID = UUID(),
        selection: M1ChannelSelection = .all
    ) async throws {
        try await updateEditingSession { session, effectsEnabled in
            try session.addChannels(
                before: id,
                nodeID: nodeID,
                selection: selection,
                effectsEnabled: effectsEnabled
            )
        }
    }

    func addGraphicEQ(before id: UUID? = nil, nodeID: UUID = UUID()) async throws {
        try await updateEditingSession { session, effectsEnabled in
            try session.addGraphicEQ(before: id, nodeID: nodeID, effectsEnabled: effectsEnabled)
        }
    }

    func addConvolution(
        before id: UUID? = nil,
        nodeID: UUID = UUID(),
        ir: M1ConvolutionIRReference
    ) async throws {
        try await updateEditingSession { session, effectsEnabled in
            try session.addConvolution(
                before: id,
                nodeID: nodeID,
                ir: ir,
                effectsEnabled: effectsEnabled
            )
        }
    }

    func deletePreamp(id: UUID) async throws {
        try await updateEditingSession { session, effectsEnabled in
            try session.deleteNode(id: id, effectsEnabled: effectsEnabled)
        }
    }

    func deleteSelectedPreamps() async throws {
        try await updateEditingSession { session, effectsEnabled in
            try session.deleteSelection(effectsEnabled: effectsEnabled)
        }
    }

    func movePreamp(id: UUID, to destination: Int) async throws {
        try await updateEditingSession { session, effectsEnabled in
            try session.moveNode(id: id, to: destination, effectsEnabled: effectsEnabled)
        }
    }

    func moveSelectedPreamps(to destination: Int, operation: M1NodeDragOperation) async throws {
        let copyCount = operation == .copy ? editingSession.selectedNodeIDs.count : 0
        let ids = (0..<copyCount).map { _ in UUID() }
        try await updateEditingSession { session, effectsEnabled in
            try session.moveSelection(
                to: destination,
                operation: operation,
                copiedIDs: ids,
                effectsEnabled: effectsEnabled
            )
        }
    }

    func moveDraggedPreamps(
        startingAt id: UUID,
        to destination: Int,
        operation: M1NodeDragOperation
    ) async throws {
        let selectionCount = editingSession.selectedNodeIDs.contains(id)
            ? editingSession.selectedNodeIDs.count
            : 1
        let ids = operation == .copy ? (0..<selectionCount).map { _ in UUID() } : []
        try await updateEditingSession { session, effectsEnabled in
            try session.moveDragSelection(
                startingAt: id,
                to: destination,
                operation: operation,
                copiedIDs: ids,
                effectsEnabled: effectsEnabled
            )
        }
    }

    func setNodeEnabled(id: UUID, enabled: Bool) async throws {
        try await updateEditingSession { session, effectsEnabled in
            try session.setNodeEnabled(id: id, enabled: enabled, effectsEnabled: effectsEnabled)
        }
    }

    func setGainDB(id: UUID, gainDB: Double) async throws {
        try await updateEditingSession { session, effectsEnabled in
            try session.setGainDB(id: id, gainDB: gainDB, effectsEnabled: effectsEnabled)
        }
    }

    func setGraphicEQPoints(id: UUID, points: [M1GraphicEQPoint]) async throws {
        try await updateEditingSession { session, effectsEnabled in
            try session.setGraphicEQPoints(
                id: id,
                points: points,
                effectsEnabled: effectsEnabled
            )
        }
    }

    func setChannels(id: UUID, channels: M1ChannelSelection) async throws {
        try await updateEditingSession { session, effectsEnabled in
            try session.setChannels(id: id, channels: channels, effectsEnabled: effectsEnabled)
        }
    }

    func setConvolutionIR(id: UUID, ir: M1ConvolutionIRReference) async throws {
        try await updateEditingSession { session, effectsEnabled in
            try session.setConvolutionIR(id: id, ir: ir, effectsEnabled: effectsEnabled)
        }
    }

    func undo() async throws {
        try await updateEditingSession { session, effectsEnabled in
            try session.undo(effectsEnabled: effectsEnabled)
        }
    }

    func redo() async throws {
        try await updateEditingSession { session, effectsEnabled in
            try session.redo(effectsEnabled: effectsEnabled)
        }
    }

    func copySelection(to pasteboard: any M1PasteboardAccess) async throws {
        guard snapshot().canUseSelection else { throw M1ProductControllerError.commandUnavailable }
        let session = editingSession
        let encoded = try await Task.detached { try session.encodedSelection() }.value
        guard let encoded else { return }
        guard await pasteboard.writeNodes(encoded.data) else {
            throw M1ProductControllerError.commandUnavailable
        }
    }

    func cutSelection(to pasteboard: any M1PasteboardAccess) async throws {
        guard snapshot().canUseSelection else { throw M1ProductControllerError.commandUnavailable }
        let capturedRevision = draftRevision
        let capturedSelection = editingSession.selectedNodeIDs
        let session = editingSession
        let encoded = try await Task.detached { try session.encodedSelection() }.value
        guard let encoded else { return }
        guard await pasteboard.writeNodes(encoded.data) else {
            throw M1ProductControllerError.commandUnavailable
        }
        guard capturedRevision == draftRevision,
              capturedSelection == editingSession.selectedNodeIDs else {
            throw M1ProductControllerError.commandUnavailable
        }
        try await deleteSelectedPreamps()
    }

    func paste(from pasteboard: any M1PasteboardAccess) async throws {
        guard snapshot().canEdit else { throw M1ProductControllerError.commandUnavailable }
        guard let data = await pasteboard.readNodes() else { return }
        let decoded: M1EncodedNodeEnvelope
        do {
            decoded = try await Task.detached { try M1NodeEnvelopeCodec.decode(data) }.value
        } catch M1EditingSessionError.unsupportedClipboardSchema {
            return
        }
        let ids = decoded.nodes.map { _ in UUID() }
        try await updateEditingSession { session, effectsEnabled in
            try session.paste(decoded.nodes, newIDs: ids, effectsEnabled: effectsEnabled)
        }
    }

    func reportCommandError(_ message: String) {
        visibleError = .technical(message)
    }

    func save() async throws {
        try requireReadyForPersistence()
        acceptedOperations += 1
        persistenceInFlight = true
        defer {
            persistenceInFlight = false
            acceptedOperations -= 1
        }
        let captured = draft
        let preparation = try await audio.prepare(configuration: captured)
        if audioState == .stopped { availableLayout = preparation.layout }
        try Task.checkCancellation()
        try await persist(
            captured,
            publishChain: true,
            preparation: preparation,
            mode: requiresRepair ? .repair : .save
        )
    }

    func setEffectsEnabled(_ enabled: Bool) async throws {
        guard bootstrapped else { throw M1ProductControllerError.notBootstrapped }
        if case .uncertain = persistence { throw M1ProductControllerError.commandUnavailable }
        guard !terminating, !requiresRepair,
              audioState == .stopped || audioState == .running
        else {
            throw M1ProductControllerError.commandUnavailable
        }
        let alreadyApplied = audioState != .running || appliedEffectsEnabled == enabled
        if !effectsUpdateInFlight, pendingEffectsIntent == nil,
           draft.effectsEnabled == enabled, alreadyApplied {
            return
        }
        try enqueueEffectsIntent(enabled)
        guard !effectsUpdateInFlight else { return }
        acceptedOperations += 1
        defer { acceptedOperations -= 1 }
        try await drainEffectsUpdates()
        if !persistenceInFlight, pendingEffectsEnabled != nil {
            persistenceInFlight = true
            defer { persistenceInFlight = false }
            try await persistPendingEffects()
        }
    }

    func setProcessingEnabled(_ enabled: Bool) async throws {
        if enabled {
            if audioState == .running {
                try await setEffectsEnabled(true)
                return
            }
            guard audioState == .stopped else {
                throw M1ProductControllerError.commandUnavailable
            }
            if !draft.effectsEnabled { try await setEffectsEnabled(true) }
            guard saved.effectsEnabled, snapshot().canStart else {
                throw M1ProductControllerError.commandUnavailable
            }
            let configuration = try beginStart()
            try await finishStart(configuration: configuration)
        } else {
            guard audioState == .running else { return }
            try await setEffectsEnabled(false)
        }
    }

    func start() async throws {
        let startupConfiguration = try beginStart()
        try await finishStart(configuration: startupConfiguration)
    }

    func beginStart() throws -> M1ConfigurationSnapshot {
        guard snapshot().canStart else { throw M1ProductControllerError.commandUnavailable }
        let startupConfiguration = persistence == .recovery ? runtimeBaseline : saved
        recoveryToken &+= 1
        pendingRecoveryReason = nil
        audioRecovery = .inactive
        audioState = .starting
        expectedDiagnostics = nil
        expectedConfigurationGeneration = nil
        visibleError = nil
        return startupConfiguration
    }

    func finishStart(configuration startupConfiguration: M1ConfigurationSnapshot) async throws {
        guard audioState == .starting else { throw M1ProductControllerError.commandUnavailable }
        let token = recoveryToken
        do {
            try await audio.start(configuration: startupConfiguration)
            guard token == recoveryToken, !isSystemSleeping else {
                try await audio.stop()
                audioState = Self.productAudioState(await audio.state())
                clearAudioProjection()
                throw CancellationError()
            }
            try await applyStartedConfiguration(startupConfiguration, token: token)
            automaticRecoveryDesired = true
            if let pendingReason = pendingRecoveryReason {
                pendingRecoveryReason = nil
                Task { await self.recoverAudio(reason: pendingReason) }
            }
        } catch {
            guard token == recoveryToken else { throw error }
            audioState = Self.productAudioState(await audio.state())
            automaticRecoveryDesired = false
            if isSystemSleeping, audioState == .stopped {
                audioRecovery = .suspendedForSleep
                visibleError = nil
            } else if error as? M1AudioRouteError == .audioCapturePermissionDenied {
                audioRecovery = .permissionRequired
                visibleError = .audioCapturePermissionRequired
            } else {
                visibleError = .technical(String(describing: error))
            }
            throw error
        }
    }

    func stop() async throws {
        recoveryToken &+= 1
        automaticRecoveryDesired = false
        recoveryInProgress = false
        pendingRecoveryReason = nil
        audioRecovery = .inactive
        let hadPendingApplication = pendingApplication != nil
        audioState = .stopping
        do {
            try await audio.stop()
            audioState = .stopped
            clearAudioProjection()
            availableLayout = await audio.discoverOutputLayout()
            if hadPendingApplication {
                persistence = draft == saved ? .savedPendingStart : .modified
            }
        } catch {
            audioState = .cleanupRequired
            visibleError = .technical(String(describing: error))
            throw error
        }
    }

    func handleRecoverableStop(
        bridgeGeneration: UInt64,
        reason: M1RetirementStopReason
    ) async {
        var stopAccepted = true
        do {
            stopAccepted = try await audio.stop(bridgeGeneration: bridgeGeneration)
        } catch {
            visibleError = .technical(String(describing: error))
        }
        guard stopAccepted else { return }
        let currentState = Self.productAudioState(await audio.state())
        audioState = currentState
        guard currentState != .running else { return }
        publicationTask?.cancel()
        publicationTask = nil
        pendingApplication = nil
        layout = nil
        activeDiagnostics = nil
        expectedDiagnostics = nil
        activeConfigurationGeneration = nil
        expectedConfigurationGeneration = nil
        realtimeDiagnostics = nil
        appliedEffectsEnabled = nil
        if currentState == .stopped {
            persistence = draft == saved ? .savedPendingStart : .modified
        }
        automaticRecoveryDesired = false
        audioRecovery = .waitingForRetry(reason: .systemAudioServicesChanged)
        visibleError = .audioStoppedAfterRetirementMaintenance(String(describing: reason))
    }

    func handleAudioLifecycleEvent(_ event: M1AudioLifecycleEvent) async {
        switch event {
        case .willSleep:
            isSystemSleeping = true
            await suspendAudioForSleep()
        case .didWake:
            guard isSystemSleeping else { return }
            isSystemSleeping = false
            await recoverAudio(reason: .wake)
        case .routeChanged:
            guard !isSystemSleeping else { return }
            if audioState == .stopped {
                availableLayout = await audio.discoverOutputLayout()
                return
            }
            if audioState == .starting {
                queueRecovery(reason: .routeChanged)
                return
            }
            await recoverAudio(reason: .routeChanged)
        case let .outputFormatChanged(output):
            guard !isSystemSleeping else { return }
            if audioState == .stopped {
                availableLayout = await audio.discoverOutputLayout()
                return
            }
            if audioState == .starting {
                queueRecovery(reason: .outputFormatChanged(output))
                return
            }
            await recoverAudio(reason: .outputFormatChanged(output))
        case .systemAudioServicesChanged:
            guard !isSystemSleeping else { return }
            if audioState == .stopped {
                availableLayout = await audio.discoverOutputLayout()
                return
            }
            if audioState == .starting {
                queueRecovery(reason: .systemAudioServicesChanged)
                return
            }
            await recoverAudio(reason: .systemAudioServicesChanged)
        case .monitoringFailed:
            audioRecovery = .waitingForRetry(reason: .systemAudioServicesChanged)
            visibleError = .audioDeviceMonitoringUnavailable
        }
    }

    func handleApplicationActivation() async {
        if audioState == .stopped, !isSystemSleeping, !terminating {
            availableLayout = await audio.discoverOutputLayout()
            return
        }
        guard audioState == .running,
              automaticRecoveryDesired,
              !recoveryInProgress,
              !isSystemSleeping,
              !terminating
        else {
            return
        }
        let token = recoveryToken
        do {
            _ = try await audio.verifyCapturePermission()
        } catch {
            guard token == recoveryToken,
                  audioState == .running,
                  !isSystemSleeping,
                  !terminating
            else {
                return
            }
            await stopAfterCapturePermissionVerificationFailure(error)
        }
    }

    private func stopAfterCapturePermissionVerificationFailure(_ verificationError: any Error) async {
        recoveryToken &+= 1
        let token = recoveryToken
        automaticRecoveryDesired = false
        recoveryInProgress = false
        pendingRecoveryReason = nil
        audioState = .stopping
        do {
            try await audio.stop()
            guard token == recoveryToken else { return }
            audioState = .stopped
            clearAudioProjection()
            if draft == saved { persistence = .savedPendingStart }
            if verificationError as? M1AudioRouteError == .audioCapturePermissionDenied {
                audioRecovery = .permissionRequired
                visibleError = .audioCapturePermissionRequired
            } else {
                audioRecovery = .waitingForRetry(reason: .systemAudioServicesChanged)
                visibleError = .capturePermissionVerificationFailed(String(describing: verificationError))
            }
        } catch {
            guard token == recoveryToken else { return }
            let currentState = Self.productAudioState(await audio.state())
            guard token == recoveryToken else { return }
            audioState = currentState
            audioRecovery = .waitingForRetry(reason: .systemAudioServicesChanged)
            visibleError = .capturePermissionCleanupFailed(String(describing: error))
        }
    }

    private func suspendAudioForSleep() async {
        guard (automaticRecoveryDesired || audioState == .starting), !terminating else { return }
        recoveryToken &+= 1
        let token = recoveryToken
        recoveryInProgress = false
        pendingRecoveryReason = nil
        audioRecovery = .suspendedForSleep
        await invalidatePendingApplication()
        audioState = .stopping
        do {
            try await audio.stop()
            guard token == recoveryToken else { return }
            audioState = .stopped
            clearAudioProjection()
            if draft == saved { persistence = .savedPendingStart }
            visibleError = nil
        } catch {
            guard token == recoveryToken else { return }
            audioState = Self.productAudioState(await audio.state())
            visibleError = .technical(String(describing: error))
        }
    }

    private func recoverAudio(reason: M1AudioRecoveryReason) async {
        guard automaticRecoveryDesired, !isSystemSleeping, !terminating else { return }
        if recoveryInProgress {
            queueRecovery(reason: reason)
            return
        }
        recoveryInProgress = true
        recoveryToken &+= 1
        let token = recoveryToken
        let recoveryNodes = requiresRepair || processingTransition != .idle
            ? runtimeBaseline.nodes
            : saved.nodes
        let configuration = M1ConfigurationSnapshot(
            effectsEnabled: runtimeBaseline.effectsEnabled,
            nodes: recoveryNodes
        )
        defer {
            if token == recoveryToken {
                recoveryInProgress = false
                if let pendingReason = pendingRecoveryReason,
                   automaticRecoveryDesired,
                   !isSystemSleeping,
                   !terminating
                {
                    pendingRecoveryReason = nil
                    Task { await self.recoverAudio(reason: pendingReason) }
                }
            }
        }

        await invalidatePendingApplication()
        if audioState != .stopped {
            audioState = .stopping
            do {
                if case let .outputFormatChanged(output) = reason {
                    try await audio.stopForOutputFormatRecovery(expectedOutput: output)
                } else {
                    try await audio.stop()
                }
            } catch {
                guard token == recoveryToken else { return }
                audioState = Self.productAudioState(await audio.state())
                automaticRecoveryDesired = false
                audioRecovery = .waitingForRetry(reason: reason)
                visibleError = .technical(String(describing: error))
                return
            }
        }
        guard token == recoveryToken else { return }
        audioState = .stopped
        clearAudioProjection()
        if draft == saved { persistence = .savedPendingStart }

        var lastError: (any Error)?
        for attempt in 1...max(1, recoveryTiming.maximumAttempts) {
            guard token == recoveryToken, automaticRecoveryDesired, !terminating else { return }
            audioRecovery = .recovering(
                reason: reason,
                attempt: attempt,
                maximumAttempts: max(1, recoveryTiming.maximumAttempts)
            )
            visibleError = nil
            do {
                let startMode: M1AudioRouteStartMode
                if case let .outputFormatChanged(output) = reason {
                    startMode = .outputFormatRecovery(expectedOutput: output)
                } else {
                    startMode = .normal
                }
                try await audio.start(configuration: configuration, mode: startMode)
                guard token == recoveryToken, automaticRecoveryDesired, !terminating else {
                    try? await audio.stop()
                    return
                }
                try await applyStartedConfiguration(
                    configuration,
                    token: token,
                    requiresRecoveryIntent: true
                )
                audioRecovery = .inactive
                await resumeRequestedEffectsAfterRecoveryIfNeeded()
                return
            } catch {
                guard token == recoveryToken else { return }
                lastError = error
                audioState = Self.productAudioState(await audio.state())
                if error is CancellationError {
                    automaticRecoveryDesired = false
                    pendingRecoveryReason = nil
                    let cleanupError = await stopAfterTerminalRecoveryFailure()
                    audioRecovery = .waitingForRetry(reason: reason)
                    visibleError = .technical(String(describing: cleanupError ?? error))
                    return
                }
                if error as? M1AudioRouteError == .audioCapturePermissionDenied {
                    automaticRecoveryDesired = false
                    if let cleanupError = await stopAfterTerminalRecoveryFailure() {
                        audioRecovery = .waitingForRetry(reason: reason)
                        visibleError = .technical(String(describing: cleanupError))
                        return
                    }
                    audioRecovery = .permissionRequired
                    visibleError = .audioCapturePermissionRequired
                    return
                }
                if audioState == .cleanupRequired {
                    automaticRecoveryDesired = false
                    let cleanupError = await stopAfterTerminalRecoveryFailure()
                    audioRecovery = .waitingForRetry(reason: reason)
                    visibleError = .technical(String(describing: cleanupError ?? error))
                    return
                }
                audioState = .stopped
                if attempt < max(1, recoveryTiming.maximumAttempts) {
                    do {
                        try await recoveryTiming.sleep(recoveryTiming.delayNanoseconds(attempt))
                    } catch {
                        automaticRecoveryDesired = false
                        pendingRecoveryReason = nil
                        let cleanupError = await stopAfterTerminalRecoveryFailure()
                        audioRecovery = .waitingForRetry(reason: reason)
                        visibleError = .technical(String(describing: cleanupError ?? error))
                        return
                    }
                }
            }
        }
        guard token == recoveryToken else { return }
        automaticRecoveryDesired = false
        pendingRecoveryReason = nil
        audioRecovery = .waitingForRetry(reason: reason)
        let cleanupError = await stopAfterTerminalRecoveryFailure()
        let failure = (cleanupError ?? lastError).map { String(describing: $0) } ?? "unknown failure"
        visibleError = .automaticAudioRecoveryPaused(failure)
    }

    private func stopAfterTerminalRecoveryFailure() async -> (any Error)? {
        do {
            try await audio.stop()
            audioState = Self.productAudioState(await audio.state())
            return nil
        } catch {
            audioState = Self.productAudioState(await audio.state())
            return error
        }
    }

    private func queueRecovery(reason: M1AudioRecoveryReason) {
        if reason.isOutputFormatChange,
           let pendingRecoveryReason,
           !pendingRecoveryReason.isOutputFormatChange
        {
            return
        }
        pendingRecoveryReason = reason
    }

    private func applyStartedConfiguration(
        _ configuration: M1ConfigurationSnapshot,
        token: UInt64,
        requiresRecoveryIntent: Bool = false
    ) async throws {
        let startedLayout = await audio.outputLayout()
        guard token == recoveryToken,
              !isSystemSleeping,
              !requiresRecoveryIntent || automaticRecoveryDesired
        else {
            throw CancellationError()
        }
        let diagnostics = await audio.processingDiagnostics()
        audioState = .running
        runtimeBaseline = configuration
        if !requiresRecoveryIntent {
            requestedEffectsEnabled = configuration.effectsEnabled
        }
        appliedEffectsEnabled = configuration.effectsEnabled
        processingTransition = .idle
        layout = startedLayout
        availableLayout = startedLayout
        activeDiagnostics = diagnostics
        expectedDiagnostics = nil
        if diagnostics != nil { activeConfigurationGeneration = commitGeneration }
        expectedConfigurationGeneration = nil
        persistence = draft == saved ? .clean : .modified
    }

    private func clearAudioProjection() {
        layout = nil
        activeDiagnostics = nil
        expectedDiagnostics = nil
        activeConfigurationGeneration = nil
        expectedConfigurationGeneration = nil
        realtimeDiagnostics = nil
        appliedEffectsEnabled = nil
        processingTransition = .idle
        pendingApplication = nil
        publicationTask?.cancel()
        publicationTask = nil
    }

    func refreshDiagnostics() async throws {
        guard audioState == .running, !terminating else {
            throw M1ProductControllerError.commandUnavailable
        }
        realtimeDiagnostics = try await audio.diagnostics()
    }

    func retryUncertainPersistence() async throws {
        guard !terminating, !persistenceInFlight else {
            throw M1ProductControllerError.commandUnavailable
        }
        guard case let .uncertain(generation) = persistence else {
            throw M1ProductControllerError.commandUnavailable
        }
        acceptedOperations += 1
        persistenceInFlight = true
        defer {
            persistenceInFlight = false
            acceptedOperations -= 1
        }
        let result = await store.retryUncertain(generation: generation)
        applyPersistenceResult(result)
        if case .succeeded = result, let application = uncertainApplication {
            let preparation: M1AudioConfigurationPreparation
            do {
                preparation = try await audio.prepare(configuration: application.snapshot)
            } catch {
                uncertainApplication = nil
                persistence = .savedPendingStart
                expectedDiagnostics = nil
                expectedConfigurationGeneration = nil
                visibleError = .technical(String(describing: error))
                throw error
            }
            let refreshedApplication = PendingApplication(
                generation: application.generation,
                snapshot: application.snapshot,
                preparation: preparation
            )
            uncertainApplication = nil
            await invalidatePendingApplication()
            try await publishIfRunning(refreshedApplication)
        }
        if case .uncertain = result { return }
        try await persistPendingEffects()
    }

    func retryOutputDiscovery() async throws {
        guard !terminating, !persistenceInFlight else {
            throw M1ProductControllerError.commandUnavailable
        }
        guard case .waitingForOutput = persistence else {
            throw M1ProductControllerError.commandUnavailable
        }
        acceptedOperations += 1
        persistenceInFlight = true
        defer {
            persistenceInFlight = false
            acceptedOperations -= 1
        }
        let preparation = try await audio.prepare(configuration: saved)
        guard preparation.layout != nil else { return }
        let application = PendingApplication(
            generation: commitGeneration,
            snapshot: saved,
            preparation: preparation
        )
        try await publishIfRunning(application)
    }

    func shutdown() async throws {
        guard !terminating else { return }
        terminating = true
        do {
            while acceptedOperations > 0 || persistenceInFlight || effectsUpdateInFlight {
                try await Task.sleep(for: .milliseconds(1))
            }
            try await stop()
        } catch {
            terminating = false
            throw error
        }
    }

    func requestTermination() async -> M1TerminationDecision {
        let waitedForAcceptedWork = acceptedOperations > 0 || persistenceInFlight || effectsUpdateInFlight
        while acceptedOperations > 0 || persistenceInFlight || effectsUpdateInFlight {
            try? await Task.sleep(for: .milliseconds(1))
        }
        if waitedForAcceptedWork, case let .failed(reason) = persistence {
            return .stayOpen(.technical(reason))
        }
        return await currentTerminationDecision()
    }

    func resolveTermination(_ action: M1TerminationAction) async -> M1TerminationDecision {
        switch action {
        case .cancel:
            return .stayOpen(.terminationCancelled)
        case .discardAndExit, .exit:
            pendingEffectsIntent = nil
            pendingEffectsEnabled = nil
            do {
                try await shutdown()
                return .terminate
            } catch {
                visibleError = .technical(String(describing: error))
                return .stayOpen(.technical(String(describing: error)))
            }
        case .saveAndExit:
            do {
                try await save()
            } catch {
                visibleError = .technical(String(describing: error))
                return .stayOpen(.technical(String(describing: error)))
            }
        case .retry:
            do {
                if case .uncertain = persistence {
                    try await retryUncertainPersistence()
                } else {
                    try await retryEffectsPersistence()
                }
            } catch {
                visibleError = .technical(String(describing: error))
                return .stayOpen(.technical(String(describing: error)))
            }
        }

        if case let .failed(reason) = persistence { return .stayOpen(.technical(reason)) }
        if case .recovery = persistence {
            return .stayOpen(visibleError ?? .configurationRepairFailed)
        }
        let decision = await currentTerminationDecision()
        guard decision == .terminate else { return decision }
        do {
            try await shutdown()
            return .terminate
        } catch {
            visibleError = .technical(String(describing: error))
            return .stayOpen(.technical(String(describing: error)))
        }
    }

    func waitForPendingApplication() async {
        await publicationTask?.value
    }

    private func persist(
        _ captured: M1ConfigurationSnapshot,
        publishChain: Bool,
        preparation: M1AudioConfigurationPreparation? = nil,
        mode: M1ConfigurationCommitMode
    ) async throws {
        guard commitGeneration < UInt64.max else { throw M1ProductControllerError.generationExhausted }
        let encoded = try await Task.detached {
            try M1ConfigurationCodec.encode(captured)
        }.value
        if pendingEffectsEnabled == captured.effectsEnabled {
            pendingEffectsEnabled = nil
        }
        commitGeneration += 1
        let generation = commitGeneration
        persistence = .saving(generation: generation)
        let result = await store.commit(encoded, generation: generation, mode: mode)
        applyPersistenceResult(result)
        let application = PendingApplication(
            generation: generation,
            snapshot: captured,
            preparation: preparation ?? .waitingForOutput
        )
        if publishChain {
            switch result {
            case .succeeded, .uncertain:
                await invalidatePendingApplication()
            case .failed:
                break
            }
        }
        if case .uncertain = result, publishChain {
            uncertainApplication = application
        } else if case .succeeded = result, publishChain {
            uncertainApplication = nil
            try await publishIfRunning(application)
        }
        if case .uncertain = result { return }
        if case .failed = result {
            do {
                try await persistPendingEffects()
            } catch {
                applyPersistenceResult(result)
                throw error
            }
            if case .uncertain = persistence { return }
            applyPersistenceResult(result)
            return
        }
        try await persistPendingEffects()
    }

    private func applyPersistenceResult(_ result: M1ConfigurationCommitResult) {
        switch result {
        case let .succeeded(_, snapshot):
            saved = snapshot
            requiresRepair = false
            persistence = draft == saved ? .clean : .modified
            visibleError = nil
            if audioState == .stopped { runtimeBaseline = snapshot }
        case let .failed(_, reason):
            persistence = requiresRepair ? .recovery : .failed(String(describing: reason))
            visibleError = .technical(String(describing: reason))
        case let .uncertain(generation, _, _):
            persistence = .uncertain(generation: generation)
            visibleError = .configurationDurabilityUncertain
        }
    }

    private func retryEffectsPersistence() async throws {
        guard !terminating, !persistenceInFlight, !effectsUpdateInFlight, !requiresRepair else {
            throw M1ProductControllerError.commandUnavailable
        }
        if case .uncertain = persistence { throw M1ProductControllerError.commandUnavailable }
        acceptedOperations += 1
        persistenceInFlight = true
        defer {
            persistenceInFlight = false
            acceptedOperations -= 1
        }
        let candidate = M1ConfigurationSnapshot(
            effectsEnabled: draft.effectsEnabled,
            nodes: saved.nodes
        )
        try await persist(candidate, publishChain: false, mode: .save)
    }

    private func currentTerminationDecision() async -> M1TerminationDecision {
        if case let .uncertain(generation) = persistence {
            return .prompt(.uncertainPersistence(generation: generation))
        }
        let nodesDirty = requiresRepair || draft.nodes != saved.nodes
        let effectsDirty = draft.effectsEnabled != saved.effectsEnabled
        if nodesDirty && effectsDirty { return .prompt(.unsavedNodesAndEffects) }
        if nodesDirty { return .prompt(.unsavedNodes) }
        if effectsDirty { return .prompt(.unsavedEffects) }
        do {
            try await shutdown()
            return .terminate
        } catch {
            visibleError = .technical(String(describing: error))
            return .stayOpen(.technical(String(describing: error)))
        }
    }

    private func persistPendingEffects() async throws {
        if case .uncertain = persistence { return }
        guard let enabled = pendingEffectsEnabled else { return }
        if !requiresRepair, saved.effectsEnabled == enabled {
            pendingEffectsEnabled = nil
            return
        }
        pendingEffectsEnabled = nil
        persistingEffectsEnabled = enabled
        defer {
            if persistingEffectsEnabled == enabled { persistingEffectsEnabled = nil }
        }
        let candidate = M1ConfigurationSnapshot(effectsEnabled: enabled, nodes: saved.nodes)
        do {
            try await persist(
                candidate,
                publishChain: false,
                mode: requiresRepair ? .repair : .save
            )
        } catch {
            if pendingEffectsEnabled == nil { pendingEffectsEnabled = enabled }
            throw error
        }
    }

    private func enqueueEffectsIntent(_ enabled: Bool) throws {
        guard nextEffectsOperationID < UInt64.max else {
            throw M1ProductControllerError.generationExhausted
        }
        activeEffectsActivationToken?.invalidate()
        nextEffectsOperationID += 1
        requestedEffectsEnabled = enabled
        pendingEffectsIntent = EffectsIntent(id: nextEffectsOperationID, enabled: enabled)
    }

    private func resumeRequestedEffectsAfterRecoveryIfNeeded() async {
        guard audioState == .running,
              appliedEffectsEnabled != requestedEffectsEnabled else {
            return
        }
        do {
            try enqueueEffectsIntent(requestedEffectsEnabled)
            guard !effectsUpdateInFlight else { return }
            acceptedOperations += 1
            defer { acceptedOperations -= 1 }
            try await drainEffectsUpdates()
            if !persistenceInFlight, pendingEffectsEnabled != nil {
                persistenceInFlight = true
                defer { persistenceInFlight = false }
                try await persistPendingEffects()
            }
        } catch {
            visibleError = .technical(String(describing: error))
        }
    }

    private func drainEffectsUpdates() async throws {
        guard !effectsUpdateInFlight else { return }
        effectsUpdateInFlight = true
        defer {
            activeEffectsActivationToken?.invalidate()
            activeEffectsActivationToken = nil
            activeEffectsOperationID = nil
            processingTransition = .idle
            effectsUpdateInFlight = false
        }
        var lastError: (any Error)?
        while let intent = pendingEffectsIntent {
            pendingEffectsIntent = nil
            activeEffectsOperationID = intent.id
            let enabled = intent.enabled
            while true {
                let capturedRevision = draftRevision
                let candidate = M1ConfigurationSnapshot(
                    effectsEnabled: enabled,
                    nodes: draft.nodes
                )
                _ = try await Task.detached {
                    try M1ConfigurationCodec.encode(candidate)
                }.value
                if pendingEffectsIntent != nil { break }
                if capturedRevision != draftRevision { continue }
                if draft != candidate {
                    draft = candidate
                    try advanceDraftRevision()
                    refreshDirtyState()
                }
                break
            }
            if pendingEffectsIntent != nil { continue }
            do {
                if audioState == .running, appliedEffectsEnabled != enabled {
                    if enabled {
                        processingTransition = .preparing
                        guard await waitForEarlierRuntimeApplication() else { continue }
                        let preparation = try await audio.prepare(configuration: runtimeBaseline)
                        if pendingEffectsIntent != nil {
                            expectedDiagnostics = nil
                            processingTransition = .idle
                            continue
                        }
                        guard preparation.layout != nil, preparation.compiled != nil else {
                            throw M1ProductControllerError.commandUnavailable
                        }
                        expectedDiagnostics = preparation.compiled?.diagnostics
                        expectedConfigurationGeneration = nil
                        let activationToken = M1EffectsActivationToken()
                        activeEffectsActivationToken = activationToken
                        processingTransition = .fadingIn
                        let diagnostics = try await audio.activateEffects(
                            preparation: preparation,
                            activationToken: activationToken
                        )
                        guard audioState == .running else {
                            throw M1ProductControllerError.commandUnavailable
                        }
                        activationToken.invalidate()
                        if activeEffectsActivationToken === activationToken {
                            activeEffectsActivationToken = nil
                        }
                        activeDiagnostics = diagnostics
                        expectedDiagnostics = nil
                    } else {
                        processingTransition = .fadingOut
                        try await audio.setEffectsEnabled(false)
                    }
                    appliedEffectsEnabled = enabled
                    runtimeBaseline.effectsEnabled = enabled
                }
                processingTransition = .idle
                activeEffectsOperationID = nil
                if pendingEffectsIntent == nil {
                    if persistingEffectsEnabled != enabled {
                        pendingEffectsEnabled = enabled
                    }
                    lastError = nil
                    if visibleError == effectsOperationError { visibleError = nil }
                    effectsOperationError = nil
                }
            } catch is CancellationError where pendingEffectsIntent != nil {
                activeEffectsActivationToken = nil
                processingTransition = .idle
                activeEffectsOperationID = nil
                expectedDiagnostics = nil
                lastError = nil
            } catch {
                activeEffectsActivationToken?.invalidate()
                activeEffectsActivationToken = nil
                processingTransition = .idle
                activeEffectsOperationID = nil
                expectedDiagnostics = nil
                let message = M1PresentationMessage.technical(String(describing: error))
                effectsOperationError = message
                visibleError = message
                lastError = error
            }
        }
        if let lastError { throw lastError }
    }

    private func waitForEarlierRuntimeApplication() async -> Bool {
        while persistenceInFlight {
            if pendingEffectsIntent != nil || audioState != .running { return false }
            do {
                try await Task.sleep(for: .milliseconds(1))
            } catch {
                return false
            }
        }
        await publicationTask?.value
        return pendingEffectsIntent == nil && audioState == .running
    }

    private func invalidatePendingApplication() async {
        let hadPendingApplication = pendingApplication != nil
        publicationTask?.cancel()
        publicationTask = nil
        pendingApplication = nil
        expectedDiagnostics = nil
        expectedConfigurationGeneration = nil
        if hadPendingApplication {
            await audio.discardPendingPublication()
        }
    }

    private func publishIfRunning(_ application: PendingApplication) async throws {
        guard application.preparation.layout != nil else {
            persistence = .waitingForOutput
            expectedDiagnostics = nil
            expectedConfigurationGeneration = nil
            return
        }
        guard audioState == .running else {
            persistence = draft == saved ? .savedPendingStart : .modified
            expectedDiagnostics = application.preparation.compiled?.diagnostics
            expectedConfigurationGeneration = application.generation
            return
        }
        do {
            let publication = try await audio.publish(
                preparation: application.preparation,
                configurationGeneration: application.generation
            )
            guard audioState == .running else {
                persistence = draft == saved ? .savedPendingStart : .modified
                expectedConfigurationGeneration = application.generation
                return
            }
            guard let publication else {
                persistence = .savedPendingStart
                expectedDiagnostics = application.preparation.compiled?.diagnostics
                expectedConfigurationGeneration = application.generation
                return
            }
            expectedDiagnostics = publication.diagnostics
            expectedConfigurationGeneration = application.generation
            if publication.disposition == .active {
                publicationTask?.cancel()
                publicationTask = nil
                pendingApplication = nil
                activeDiagnostics = publication.diagnostics
                expectedDiagnostics = nil
                activeConfigurationGeneration = application.generation
                expectedConfigurationGeneration = nil
                adoptRuntimeNodes(from: application.snapshot)
                persistence = draft == saved ? .clean : .modified
                return
            }
            let pending = PendingApplication(
                generation: application.generation,
                snapshot: application.snapshot,
                preparation: M1AudioConfigurationPreparation(
                    layout: application.preparation.layout,
                    compiled: application.preparation.compiled,
                    bridgeGeneration: application.preparation.bridgeGeneration
                )
            )
            pendingApplication = pending
            persistence = .pendingApplication(generation: application.generation)
            publicationTask?.cancel()
            publicationTask = Task {
                let promoted = await audio.waitForPublication(
                    configurationGeneration: pending.generation
                )
                guard !Task.isCancelled else { return }
                self.completePendingApplication(pending, promoted: promoted)
            }
        } catch {
            persistence = draft == saved ? .savedPendingStart : .modified
            expectedDiagnostics = application.preparation.compiled?.diagnostics
            expectedConfigurationGeneration = application.generation
            visibleError = .technical(String(describing: error))
            throw error
        }
    }

    private func completePendingApplication(_ application: PendingApplication, promoted: Bool) {
        guard pendingApplication?.generation == application.generation else { return }
        pendingApplication = nil
        publicationTask = nil
        guard promoted, audioState == .running else {
            if audioState == .stopped || audioState == .stopping {
                updatePersistenceAfterPendingApplication(
                    generation: application.generation,
                    stopped: true
                )
            }
            return
        }
        activeDiagnostics = application.preparation.compiled?.diagnostics
        expectedDiagnostics = nil
        activeConfigurationGeneration = application.generation
        expectedConfigurationGeneration = nil
        adoptRuntimeNodes(from: application.snapshot)
        updatePersistenceAfterPendingApplication(
            generation: application.generation,
            stopped: false
        )
    }

    private func adoptRuntimeNodes(from snapshot: M1ConfigurationSnapshot) {
        runtimeBaseline = M1ConfigurationSnapshot(
            effectsEnabled: appliedEffectsEnabled ?? runtimeBaseline.effectsEnabled,
            nodes: snapshot.nodes
        )
    }

    private func updatePersistenceAfterPendingApplication(generation: UInt64, stopped: Bool) {
        let canUpdate: Bool
        switch persistence {
        case let .pendingApplication(currentGeneration):
            canUpdate = currentGeneration == generation
        case .clean, .modified, .savedPendingStart:
            canUpdate = true
        default:
            canUpdate = false
        }
        guard canUpdate else { return }
        persistence = stopped && draft == saved ? .savedPendingStart : (draft == saved ? .clean : .modified)
    }

    private func updateEditingSession(
        _ mutation: @escaping @Sendable (inout M1EditingSession, Bool) throws -> Void
    ) async throws {
        guard snapshot().canEdit else { throw M1ProductControllerError.commandUnavailable }
        acceptedOperations += 1
        defer { acceptedOperations -= 1 }
        while true {
            try Task.checkCancellation()
            let capturedRevision = draftRevision
            let current = editingSession
            let effectsEnabled = draft.effectsEnabled
            let updated = try await Task.detached {
                var session = current
                try mutation(&session, effectsEnabled)
                return session
            }.value
            if capturedRevision != draftRevision { continue }
            let nodesChanged = updated.nodes != editingSession.nodes
            editingSession = updated
            guard nodesChanged else { return }
            draft.nodes = updated.nodes
            try advanceDraftRevision()
            refreshDirtyState()
            return
        }
    }

    private func requireReadyForPersistence() throws {
        guard bootstrapped, !persistenceInFlight, !effectsUpdateInFlight, !terminating,
              audioState == .stopped || audioState == .running
        else {
            throw M1ProductControllerError.commandUnavailable
        }
        if case .uncertain = persistence { throw M1ProductControllerError.commandUnavailable }
    }

    private static func productAudioState(_ state: M1NativeAudioRouteState) -> M1ProductAudioState {
        switch state {
        case .stopped: return .stopped
        case .starting: return .starting
        case .running: return .running
        case .cleanupRequired: return .cleanupRequired
        }
    }

    private func advanceDraftRevision() throws {
        guard draftRevision < UInt64.max else { throw M1ProductControllerError.generationExhausted }
        draftRevision += 1
    }

    private func refreshDirtyState() {
        switch persistence {
        case .saving, .uncertain, .recovery:
            break
        default:
            persistence = draft == saved ? .clean : .modified
        }
    }
}
