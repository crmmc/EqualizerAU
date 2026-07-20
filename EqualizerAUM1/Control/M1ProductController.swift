import Foundation

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

protocol M1ProductAudioControlling: Sendable {
    func state() async -> M1NativeAudioRouteState
    func start(configuration: M1ConfigurationSnapshot) async throws
    func stop() async throws
    func stop(bridgeGeneration: UInt64) async throws
    func outputLayout() async -> M1OutputLayoutSnapshot?
    func prepare(configuration: M1ConfigurationSnapshot) async throws -> M1AudioConfigurationPreparation
    func publish(
        preparation: M1AudioConfigurationPreparation,
        configurationGeneration: UInt64
    ) async throws -> M1PreparedPublication?
    func waitForPublication(configurationGeneration: UInt64) async -> Bool
    func setEffectsEnabled(_ enabled: Bool) async throws
}

extension M1NativeAudioRouteCoordinator: M1ProductAudioControlling {}

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

struct M1ProductSnapshot: Equatable, Sendable {
    let draft: M1ConfigurationSnapshot
    let selectedNodeID: UUID?
    let persistence: M1ProductPersistenceState
    let audio: M1ProductAudioState
    let outputLayout: M1OutputLayoutSnapshot?
    let activeDiagnostics: M1ProcessingBuildDiagnostics?
    let expectedDiagnostics: M1ProcessingBuildDiagnostics?
    let canEdit: Bool
    let canSetEffects: Bool
    let canSave: Bool
    let canStart: Bool
    let canStop: Bool
    let visibleError: String?
}

enum M1ProductControllerError: Error, Equatable, Sendable {
    case notBootstrapped
    case commandUnavailable
    case nodeNotFound
    case generationExhausted
}

actor M1ProductController {
    private struct PendingApplication: Sendable {
        let generation: UInt64
        let snapshot: M1ConfigurationSnapshot
        let preparation: M1AudioConfigurationPreparation
    }

    private let store: any M1ConfigurationStoring
    private let audio: any M1ProductAudioControlling
    private var draft = M1ConfigurationSnapshot.transparentRecovery
    private var saved = M1ConfigurationSnapshot.transparentRecovery
    private var runtimeBaseline = M1ConfigurationSnapshot.transparentRecovery
    private var selectedNodeID: UUID?
    private var persistence: M1ProductPersistenceState = .recovery
    private var audioState: M1ProductAudioState = .stopped
    private var layout: M1OutputLayoutSnapshot?
    private var activeDiagnostics: M1ProcessingBuildDiagnostics?
    private var expectedDiagnostics: M1ProcessingBuildDiagnostics?
    private var visibleError: String?
    private var commitGeneration: UInt64 = 0
    private var draftRevision: UInt64 = 0
    private var bootstrapped = false
    private var bootstrapInProgress = false
    private var persistenceInFlight = false
    private var acceptedOperations = 0
    private var effectsUpdateInFlight = false
    private var pendingEffectsIntent: Bool?
    private var pendingEffectsEnabled: Bool?
    private var uncertainApplication: PendingApplication?
    private var pendingApplication: PendingApplication?
    private var publicationTask: Task<Void, Never>?
    private var terminating = false
    private var requiresRepair = false

    init(store: any M1ConfigurationStoring, audio: any M1ProductAudioControlling) {
        self.store = store
        self.audio = audio
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
            visibleError = String(describing: reason)
        case let .uncertain(generation, snapshot, _):
            draft = snapshot
            saved = snapshot
            runtimeBaseline = snapshot
            commitGeneration = generation
            persistence = .uncertain(generation: generation)
        }
        selectedNodeID = draft.nodes.first?.id
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
            selectedNodeID: selectedNodeID,
            persistence: persistence,
            audio: audioState,
            outputLayout: layout,
            activeDiagnostics: activeDiagnostics,
            expectedDiagnostics: expectedDiagnostics,
            canEdit: bootstrapped && !uncertain && !terminating,
            canSetEffects: bootstrapped && !uncertain && !recovery && !terminating
                && (audioState == .stopped || audioState == .running),
            canSave: bootstrapped && !uncertain && !persistenceInFlight && !effectsUpdateInFlight
                && !terminating && (audioState == .stopped || audioState == .running)
                && (recovery || waitingForOutput || draft != saved),
            canStart: bootstrapped && !uncertain && !persistenceInFlight && !effectsUpdateInFlight
                && !terminating && audioState == .stopped,
            canStop: audioState != .stopped,
            visibleError: visibleError
        )
    }

    func selectNode(_ id: UUID?) {
        guard id == nil || draft.nodes.contains(where: { $0.id == id }) else { return }
        selectedNodeID = id
    }

    func addPreamp(before id: UUID? = nil, nodeID: UUID = UUID()) throws {
        try edit { nodes in
            let node = M1PreampNode(id: nodeID, isEnabled: true, gainDB: 0, channels: .all)
            if let id, let index = nodes.firstIndex(where: { $0.id == id }) {
                nodes.insert(node, at: index)
            } else {
                nodes.append(node)
            }
        }
    }

    func deletePreamp(id: UUID) throws {
        try edit { nodes in
            guard let index = nodes.firstIndex(where: { $0.id == id }) else {
                throw M1ProductControllerError.nodeNotFound
            }
            nodes.remove(at: index)
            if selectedNodeID == id {
                selectedNodeID = nodes.indices.contains(index) ? nodes[index].id : nodes.last?.id
            }
        }
    }

    func movePreamp(id: UUID, to destination: Int) throws {
        try edit { nodes in
            guard let source = nodes.firstIndex(where: { $0.id == id }) else {
                throw M1ProductControllerError.nodeNotFound
            }
            let node = nodes.remove(at: source)
            nodes.insert(node, at: min(max(destination, 0), nodes.count))
        }
    }

    func setNodeEnabled(id: UUID, enabled: Bool) throws {
        try updateNode(id: id) { $0.isEnabled = enabled }
    }

    func setGainDB(id: UUID, gainDB: Double) throws {
        try updateNode(id: id) { $0.gainDB = gainDB }
    }

    func setChannels(id: UUID, channels: M1ChannelSelection) throws {
        try updateNode(id: id) { $0.channels = channels }
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
        guard draft.effectsEnabled != enabled else { return }
        acceptedOperations += 1
        defer { acceptedOperations -= 1 }
        draft.effectsEnabled = enabled
        try advanceDraftRevision()
        refreshDirtyState()
        pendingEffectsIntent = enabled
        try await drainEffectsUpdates()
        if !persistenceInFlight, pendingEffectsEnabled != nil {
            persistenceInFlight = true
            defer { persistenceInFlight = false }
            try await persistPendingEffects()
        }
    }

    func start() async throws {
        let startupConfiguration = try beginStart()
        try await finishStart(configuration: startupConfiguration)
    }

    func beginStart() throws -> M1ConfigurationSnapshot {
        guard snapshot().canStart else { throw M1ProductControllerError.commandUnavailable }
        let startupConfiguration = persistence == .recovery ? runtimeBaseline : saved
        audioState = .starting
        visibleError = nil
        return startupConfiguration
    }

    func finishStart(configuration startupConfiguration: M1ConfigurationSnapshot) async throws {
        guard audioState == .starting else { throw M1ProductControllerError.commandUnavailable }
        do {
            try await audio.start(configuration: startupConfiguration)
            audioState = .running
            runtimeBaseline = startupConfiguration
            layout = await audio.outputLayout()
            if let layout {
                activeDiagnostics = try M1ProcessingBuilder.build(
                    nodes: startupConfiguration.nodes,
                    layout: layout
                ).diagnostics
            }
            persistence = draft == saved ? .clean : .modified
        } catch {
            audioState = Self.productAudioState(await audio.state())
            visibleError = String(describing: error)
            throw error
        }
    }

    func stop() async throws {
        guard audioState != .stopped else { return }
        let hadPendingApplication = pendingApplication != nil
        audioState = .stopping
        do {
            try await audio.stop()
            audioState = .stopped
            layout = nil
            activeDiagnostics = nil
            expectedDiagnostics = nil
            pendingApplication = nil
            publicationTask?.cancel()
            publicationTask = nil
            if hadPendingApplication {
                persistence = draft == saved ? .savedPendingStart : .modified
            }
        } catch {
            audioState = .cleanupRequired
            visibleError = String(describing: error)
            throw error
        }
    }

    func handleRecoverableStop(
        bridgeGeneration: UInt64,
        reason: M1RetirementStopReason
    ) async {
        do {
            try await audio.stop(bridgeGeneration: bridgeGeneration)
        } catch {
            visibleError = String(describing: error)
        }
        let currentState = Self.productAudioState(await audio.state())
        audioState = currentState
        guard currentState != .running else { return }
        publicationTask?.cancel()
        publicationTask = nil
        pendingApplication = nil
        layout = nil
        activeDiagnostics = nil
        expectedDiagnostics = nil
        if currentState == .stopped {
            persistence = draft == saved ? .savedPendingStart : .modified
        }
        visibleError = "Audio stopped after retirement maintenance: \(reason)"
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
            uncertainApplication = nil
            try await publishIfRunning(application)
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
        if case .uncertain = result, publishChain {
            uncertainApplication = application
        } else if case .succeeded = result, publishChain {
            uncertainApplication = nil
            try await publishIfRunning(application)
        }
        if case .uncertain = result { return }
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
            visibleError = String(describing: reason)
        case let .uncertain(generation, _, _):
            persistence = .uncertain(generation: generation)
            visibleError = "Configuration durability is uncertain"
        }
    }

    private func persistPendingEffects() async throws {
        if case .uncertain = persistence { return }
        guard let enabled = pendingEffectsEnabled else { return }
        pendingEffectsEnabled = nil
        let candidate = M1ConfigurationSnapshot(effectsEnabled: enabled, nodes: saved.nodes)
        try await persist(
            candidate,
            publishChain: false,
            mode: requiresRepair ? .repair : .save
        )
    }

    private func drainEffectsUpdates() async throws {
        guard !effectsUpdateInFlight else { return }
        effectsUpdateInFlight = true
        defer { effectsUpdateInFlight = false }
        var lastError: (any Error)?
        while let enabled = pendingEffectsIntent {
            pendingEffectsIntent = nil
            do {
                if audioState == .running {
                    try await audio.setEffectsEnabled(enabled)
                }
                if pendingEffectsIntent == nil {
                    pendingEffectsEnabled = enabled
                    lastError = nil
                }
            } catch {
                visibleError = String(describing: error)
                lastError = error
            }
        }
        if let lastError { throw lastError }
    }

    private func publishIfRunning(_ application: PendingApplication) async throws {
        guard application.preparation.layout != nil else {
            persistence = .waitingForOutput
            expectedDiagnostics = nil
            return
        }
        guard audioState == .running else {
            persistence = draft == saved ? .savedPendingStart : .modified
            expectedDiagnostics = application.preparation.compiled?.diagnostics
            return
        }
        do {
            let publication = try await audio.publish(
                preparation: application.preparation,
                configurationGeneration: application.generation
            )
            guard audioState == .running else {
                persistence = draft == saved ? .savedPendingStart : .modified
                return
            }
            guard let publication else {
                persistence = .savedPendingStart
                expectedDiagnostics = application.preparation.compiled?.diagnostics
                return
            }
            expectedDiagnostics = publication.diagnostics
            if publication.disposition == .active {
                activeDiagnostics = publication.diagnostics
                expectedDiagnostics = nil
                runtimeBaseline = application.snapshot
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
            visibleError = String(describing: error)
            throw error
        }
    }

    private func completePendingApplication(_ application: PendingApplication, promoted: Bool) {
        guard pendingApplication?.generation == application.generation else { return }
        pendingApplication = nil
        publicationTask = nil
        guard promoted, audioState == .running else {
            if audioState == .stopped || audioState == .stopping {
                persistence = draft == saved ? .savedPendingStart : .modified
            }
            return
        }
        activeDiagnostics = application.preparation.compiled?.diagnostics
        expectedDiagnostics = nil
        runtimeBaseline = application.snapshot
        persistence = draft == saved ? .clean : .modified
    }

    private func edit(_ mutation: (inout [M1PreampNode]) throws -> Void) throws {
        guard snapshot().canEdit else { throw M1ProductControllerError.commandUnavailable }
        var candidate = draft.nodes
        try mutation(&candidate)
        var snapshot = draft
        snapshot.nodes = candidate
        _ = try M1ConfigurationCodec.encode(snapshot)
        draft = snapshot
        try advanceDraftRevision()
        refreshDirtyState()
    }

    private func updateNode(id: UUID, mutation: (inout M1PreampNode) -> Void) throws {
        try edit { nodes in
            guard let index = nodes.firstIndex(where: { $0.id == id }) else {
                throw M1ProductControllerError.nodeNotFound
            }
            mutation(&nodes[index])
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
