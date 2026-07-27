import Foundation

enum M1AudioRouteStartMode: Equatable, Sendable {
    case normal
    case outputFormatRecovery(expectedOutput: M1MonitoredOutputIdentity)
}

struct M1OutputFormatStabilityTiming: Sendable {
    let maximumObservations: Int
    let delayNanoseconds: UInt64
    let sleep: @Sendable (UInt64) async throws -> Void

    static let production = M1OutputFormatStabilityTiming(
        maximumObservations: 6,
        delayNanoseconds: 50_000_000,
        sleep: { try await Task.sleep(nanoseconds: $0) }
    )
}

protocol M1RuntimeCreating: Sendable {
    func createRuntime(
        bridgeGeneration: UInt64,
        initialState: M1RuntimeInitialState,
        maximumFrameCount: Int,
        sampleRate: Double
    ) throws -> M1RuntimeHandleLease
    func destroyRuntime(_ runtime: M1RuntimeHandleLease)
}

struct M1RuntimeInitialState: Equatable, Sendable {
    let stagesByChannel: [[M1CompiledProcessingStage]]
    let effectsEnabled: Bool
}

enum M1PreparedPublicationDisposition: Equatable, Sendable {
    case active
    case pending
}

struct M1RuntimePreparedPublication: Equatable, Sendable {
    let disposition: M1PreparedPublicationDisposition
    let retirementTicket: UInt64?
}

struct M1PreparedPublication: Equatable, Sendable {
    let disposition: M1PreparedPublicationDisposition
    let diagnostics: M1ProcessingBuildDiagnostics
}

struct M1AudioConfigurationPreparation: Equatable, Sendable {
    let layout: M1OutputLayoutSnapshot?
    let compiled: M1CompiledPreampTargets?
    let bridgeGeneration: UInt64?

    static let waitingForOutput = M1AudioConfigurationPreparation(
        layout: nil,
        compiled: nil,
        bridgeGeneration: nil
    )
}

struct M1RealtimeDiagnostics: Equatable, Sendable {
    let io: M1AudioIOHostCounters
    let runtime: M1RuntimeCounters
}

enum M1NativeAudioRouteState: Equatable, Sendable {
    case stopped
    case starting(generation: M1AudioRouteGeneration)
    case running(generation: M1AudioRouteGeneration, bridgeGeneration: UInt64)
    case cleanupRequired(generation: M1AudioRouteGeneration)
}

actor M1NativeAudioRouteCoordinator {
    private final class RouteResources: @unchecked Sendable {
        enum Phase {
            case starting
            case running
            case stopping
            case cleanupRequired
        }

        let generation: M1AudioRouteGeneration
        let bridgeGeneration: UInt64
        var output: M1OutputDeviceSnapshot?
        var tap: M1ProcessTapResource?
        var aggregate: M1AggregateResource?
        var runtime: M1RuntimeHandleLease?
        var diagnostics: M1ProcessingBuildDiagnostics?
        var runtimeLeaseInstalled = false
        var io: M1AudioIOResource?
        var phase: Phase = .starting

        init(generation: M1AudioRouteGeneration, bridgeGeneration: UInt64) {
            self.generation = generation
            self.bridgeGeneration = bridgeGeneration
        }
    }

    private let routeResources: M1AudioRouteResourceController
    private let audioIO: M1AudioIOController
    private let runtimeFactory: any M1RuntimeCreating
    private let runtimeAccess: M1RuntimeLeaseAccess
    private let retirementMaintenance: M1RetirementMaintenanceCoordinator
    private let irLoader: any M1ConvolutionIRLoading
    private let outputFormatStabilityTiming: M1OutputFormatStabilityTiming
    private var current: RouteResources?
    private var nextGeneration: UInt64 = 0
    private var nextBridgeGeneration: UInt64 = 0
    private var operationInProgress = false
    private var stopInProgress = false
    private var startInProgress = false
    private var startCancellationRequested = false
    private var formatRecoveryGuard: M1ProcessTapResource?
    private var formatRecoveryGuardBridgeGeneration: UInt64?
    private var formatRecoveryGuardCleanupRequired = false
    private var capturePermissionProbeInProgress = false

    init(
        routeResources: M1AudioRouteResourceController,
        audioIO: M1AudioIOController,
        runtimeFactory: any M1RuntimeCreating,
        runtimeAccess: M1RuntimeLeaseAccess,
        retirementMaintenance: M1RetirementMaintenanceCoordinator,
        irLoader: any M1ConvolutionIRLoading = M1ConvolutionIRStore(),
        outputFormatStabilityTiming: M1OutputFormatStabilityTiming = .production
    ) {
        self.routeResources = routeResources
        self.audioIO = audioIO
        self.runtimeFactory = runtimeFactory
        self.runtimeAccess = runtimeAccess
        self.retirementMaintenance = retirementMaintenance
        self.irLoader = irLoader
        precondition(outputFormatStabilityTiming.maximumObservations >= 2)
        self.outputFormatStabilityTiming = outputFormatStabilityTiming
    }

    func state() -> M1NativeAudioRouteState {
        guard let current else {
            if formatRecoveryGuardCleanupRequired, let formatRecoveryGuard {
                return .cleanupRequired(generation: formatRecoveryGuard.descriptor.generation)
            }
            return .stopped
        }
        switch current.phase {
        case .starting:
            return .starting(generation: current.generation)
        case .running:
            return .running(
                generation: current.generation,
                bridgeGeneration: current.bridgeGeneration
            )
        case .stopping, .cleanupRequired:
            return .cleanupRequired(generation: current.generation)
        }
    }

    func start() async throws {
        try await start(configuration: .transparentRecovery)
    }

    func start(configuration: M1ConfigurationSnapshot) async throws {
        try await start(configuration: configuration, mode: .normal)
    }

    func start(configuration: M1ConfigurationSnapshot, mode: M1AudioRouteStartMode) async throws {
        guard current == nil, !operationInProgress else {
            throw M1AudioIOError.invalidState("route is already active or changing")
        }
        operationInProgress = true
        startInProgress = true
        startCancellationRequested = false
        defer {
            operationInProgress = false
            startInProgress = false
            startCancellationRequested = false
        }
        try await routeResources.cleanupPendingResources()
        try checkStartCancellation()
        guard nextGeneration < UInt64.max, nextBridgeGeneration < UInt64.max else {
            throw M1AudioIOError.invalidState("audio route generation is exhausted")
        }
        nextGeneration += 1
        nextBridgeGeneration += 1
        let resources = RouteResources(
            generation: M1AudioRouteGeneration(rawValue: nextGeneration),
            bridgeGeneration: nextBridgeGeneration
        )
        current = resources

        do {
            let discovery = try await discoverOutput(generation: resources.generation, mode: mode)
            let output = discovery.output
            resources.output = output
            if !discovery.usesFormatRecoveryRelease {
                try await destroyFormatRecoveryGuard()
            }
            try checkStartCancellation()
            let tap = try await routeResources.createTap(
                generation: resources.generation,
                output: output,
                handoverGuard: discovery.usesFormatRecoveryRelease ? formatRecoveryGuard : nil
            )
            resources.tap = tap
            try checkStartCancellation()
            let aggregate = try await routeResources.createAggregate(
                generation: resources.generation,
                output: output,
                tap: tap
            )
            resources.aggregate = aggregate
            try checkStartCancellation()
            let irLoader = irLoader
            let compiled = try await detachedValue {
                try M1ProcessingBuilder.build(
                    nodes: configuration.nodes,
                    layout: output.layout,
                    irLoader: irLoader
                )
            }
            try checkStartCancellation()
            let runtime = try runtimeFactory.createRuntime(
                bridgeGeneration: resources.bridgeGeneration,
                initialState: M1RuntimeInitialState(
                    stagesByChannel: compiled.stagesByChannel,
                    effectsEnabled: configuration.effectsEnabled
                ),
                maximumFrameCount: aggregate.maximumFrameCount,
                sampleRate: output.layout.sampleRate
            )
            resources.runtime = runtime
            resources.diagnostics = compiled.diagnostics
            try checkStartCancellation()
            guard await runtimeAccess.install(runtime) else {
                throw M1AudioIOError.invalidState("runtime lease is already installed")
            }
            resources.runtimeLeaseInstalled = true
            try checkStartCancellation()
            let io = try await audioIO.create(
                generation: resources.generation,
                bridgeGeneration: resources.bridgeGeneration,
                aggregate: aggregate,
                output: output,
                runtime: runtime,
                startupSilentFrames: try startupSilentFrames(
                    for: output,
                    usesFormatRecoveryRelease: discovery.usesFormatRecoveryRelease
                )
            )
            resources.io = io
            try checkStartCancellation()
            try await routeResources.prepareTapForCapture(tap)
            try checkStartCancellation()
            try await audioIO.startCapture(io)
            try checkStartCancellation()
            try await audioIO.createOutput(io)
            try checkStartCancellation()
            try await audioIO.startOutput(io)
            try checkStartCancellation()
            try await destroyFormatRecoveryGuard()
            try checkStartCancellation()
            resources.phase = .running
        } catch {
            let startError = error
            do {
                try await cleanup(resources)
            } catch {
                throw error
            }
            if startError is CancellationError {
                try await destroyFormatRecoveryGuard()
            }
            throw startError
        }
    }

    private func discoverOutput(
        generation: M1AudioRouteGeneration,
        mode: M1AudioRouteStartMode
    ) async throws -> (output: M1OutputDeviceSnapshot, usesFormatRecoveryRelease: Bool) {
        guard case let .outputFormatRecovery(expectedOutput) = mode else {
            return (try await routeResources.discoverOutput(generation: generation), false)
        }
        var previous: M1OutputDeviceSnapshot?
        for observation in 1...outputFormatStabilityTiming.maximumObservations {
            try checkStartCancellation()
            let current = try await routeResources.discoverOutput(generation: generation)
            guard current.objectID == expectedOutput.objectID,
                  current.uid == expectedOutput.persistentUID
            else {
                return (current, false)
            }
            if let previous,
               previous.objectID == current.objectID,
               previous.uid == current.uid,
               previous.layout == current.layout
            {
                return (current, true)
            }
            previous = current
            if observation < outputFormatStabilityTiming.maximumObservations {
                try await outputFormatStabilityTiming.sleep(outputFormatStabilityTiming.delayNanoseconds)
            }
        }
        throw M1AudioRouteError.invalidOutputDevice("output format did not stabilize")
    }

    private func startupSilentFrames(
        for output: M1OutputDeviceSnapshot,
        usesFormatRecoveryRelease: Bool
    ) throws -> Int {
        guard usesFormatRecoveryRelease else { return 0 }
        let frames = ceil(output.layout.sampleRate * 0.050)
        guard frames.isFinite, frames > 0, frames <= Double(UInt32.max) else {
            throw M1AudioRouteError.invalidOutputDevice("startup silence frame count is invalid")
        }
        return Int(frames)
    }

    func outputLayout() -> M1OutputLayoutSnapshot? {
        guard current?.phase == .running else { return nil }
        return current?.output?.layout
    }

    func processingDiagnostics() -> M1ProcessingBuildDiagnostics? {
        guard current?.phase == .running else { return nil }
        return current?.diagnostics
    }

    func discoverOutputLayout() async -> M1OutputLayoutSnapshot? {
        if let output = current?.output { return output.layout }
        guard !operationInProgress, nextGeneration < UInt64.max else { return nil }
        do {
            let generation = M1AudioRouteGeneration(rawValue: nextGeneration + 1)
            return try await routeResources.discoverOutput(generation: generation).layout
        } catch {
            return nil
        }
    }

    func diagnostics() async throws -> M1RealtimeDiagnostics? {
        guard let current, current.phase == .running, let io = current.io else { return nil }
        let ioCounters: M1AudioIOHostCounters
        let runtimeCounters: M1RuntimeCounters
        do {
            ioCounters = try await audioIO.diagnostics(io)
            runtimeCounters = try await runtimeAccess.diagnostics(
                bridgeGeneration: current.bridgeGeneration
            )
        } catch {
            guard self.current === current, current.phase == .running else { return nil }
            throw error
        }
        guard self.current === current, current.phase == .running else { return nil }
        return M1RealtimeDiagnostics(io: ioCounters, runtime: runtimeCounters)
    }

    func prepare(configuration: M1ConfigurationSnapshot) async throws -> M1AudioConfigurationPreparation {
        if let current, current.phase == .running, let output = current.output {
            let irLoader = irLoader
            let compiled = try await detachedValue {
                try M1ProcessingBuilder.build(
                    nodes: configuration.nodes,
                    layout: output.layout,
                    irLoader: irLoader
                )
            }
            guard self.current === current, current.phase == .running else {
                return .waitingForOutput
            }
            return M1AudioConfigurationPreparation(
                layout: output.layout,
                compiled: compiled,
                bridgeGeneration: current.bridgeGeneration
            )
        }
        try M1ProcessingBuilder.validate(nodes: configuration.nodes)
        let convolutionNodes = configuration.nodes.filter { $0.kind == .convolution && $0.isEnabled }
        guard convolutionNodes.count <= M1ProcessingBuilder.maximumConvolutionStages else {
            throw M1ProcessingBuildError.convolutionStageCapacityExceeded
        }
        let irLoader = irLoader
        try await detachedValue {
            var validatedReferences: [M1ConvolutionIRReference] = []
            for node in convolutionNodes {
                try Task.checkCancellation()
                let ir = node.convolutionIR!
                guard !validatedReferences.contains(ir) else { continue }
                do {
                    try irLoader.validate(reference: ir)
                } catch let error as M1ConvolutionIRError {
                    throw M1ProcessingBuildError.convolutionIRLoadFailed(nodeID: node.id, error: error)
                }
                validatedReferences.append(ir)
            }
        }
        guard current == nil, !operationInProgress, nextGeneration < UInt64.max else {
            return .waitingForOutput
        }
        do {
            let discoveryGeneration = M1AudioRouteGeneration(rawValue: nextGeneration + 1)
            let output = try await routeResources.discoverOutput(generation: discoveryGeneration)
            let irLoader = irLoader
            let compiled = try await detachedValue {
                try M1ProcessingBuilder.build(
                    nodes: configuration.nodes,
                    layout: output.layout,
                    irLoader: irLoader
                )
            }
            guard current == nil, !operationInProgress else { return .waitingForOutput }
            return M1AudioConfigurationPreparation(
                layout: output.layout,
                compiled: compiled,
                bridgeGeneration: nil
            )
        } catch let error as M1ProcessingBuildError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .waitingForOutput
        }
    }

    func publish(
        preparation: M1AudioConfigurationPreparation,
        configurationGeneration: UInt64
    ) async throws -> M1PreparedPublication? {
        guard let current,
              current.phase == .running,
              preparation.bridgeGeneration == current.bridgeGeneration,
              preparation.layout == current.output?.layout,
              let compiled = preparation.compiled
        else {
            return nil
        }
        let runtimePublication: M1RuntimePreparedPublication
        do {
            runtimePublication = try await runtimeAccess.publish(
                stagesByChannel: compiled.stagesByChannel,
                configurationGeneration: configurationGeneration,
                bridgeGeneration: current.bridgeGeneration
            )
        } catch {
            guard self.current === current, current.phase == .running else { return nil }
            throw error
        }
        guard self.current === current, current.phase == .running else { return nil }
        if let ticket = runtimePublication.retirementTicket {
            _ = await retirementMaintenance.start(
                ticket: ticket,
                bridgeGeneration: current.bridgeGeneration
            )
        }
        return M1PreparedPublication(
            disposition: runtimePublication.disposition,
            diagnostics: compiled.diagnostics
        )
    }

    func setEffectsEnabled(_ enabled: Bool) async throws {
        guard let current, current.phase == .running else { return }
        try await runtimeAccess.setEffectsEnabled(enabled, bridgeGeneration: current.bridgeGeneration)
    }

    func waitForPublication(configurationGeneration: UInt64) async -> Bool {
        guard let current, current.phase == .running else { return false }
        let bridgeGeneration = current.bridgeGeneration
        await retirementMaintenance.waitUntilIdle()
        guard self.current === current, current.phase == .running else { return false }
        let generations = await runtimeAccess.configurationGenerations(
            bridgeGeneration: bridgeGeneration
        )
        return generations?.active == configurationGeneration
    }

    func discardPendingPublication() async {
        guard let current, current.phase == .running else { return }
        let bridgeGeneration = current.bridgeGeneration
        let maintenanceOwnsGeneration = await retirementMaintenance.discardPending(
            bridgeGeneration: bridgeGeneration
        )
        if !maintenanceOwnsGeneration {
            await runtimeAccess.discardPendingPrepared(bridgeGeneration: bridgeGeneration)
        }
    }

    func stop() async throws {
        if startInProgress {
            startCancellationRequested = true
            while startInProgress {
                await Task.yield()
            }
        }
        while capturePermissionProbeInProgress {
            await Task.yield()
        }
        while stopInProgress {
            await Task.yield()
        }
        guard !operationInProgress else {
            throw M1AudioIOError.invalidState("route operation is already in progress")
        }
        operationInProgress = true
        stopInProgress = true
        defer {
            stopInProgress = false
            operationInProgress = false
        }
        var firstError: (any Error)?
        if let current {
            do {
                try await cleanup(current)
            } catch {
                firstError = error
            }
        }
        do {
            try await destroyFormatRecoveryGuard()
        } catch {
            if firstError == nil { firstError = error }
        }
        if let firstError { throw firstError }
    }

    func stopForOutputFormatRecovery(expectedOutput: M1MonitoredOutputIdentity) async throws {
        while capturePermissionProbeInProgress {
            await Task.yield()
        }
        guard let current,
              current.output?.objectID == expectedOutput.objectID,
              current.output?.uid == expectedOutput.persistentUID
        else {
            try await stop()
            return
        }
        guard !operationInProgress, formatRecoveryGuard == nil else {
            throw M1AudioIOError.invalidState("route operation is already in progress")
        }
        operationInProgress = true
        stopInProgress = true
        defer {
            stopInProgress = false
            operationInProgress = false
        }
        try await cleanup(current, preserveTapAsFormatRecoveryGuard: true)
    }

    func verifyCapturePermission() async throws -> Bool {
        guard !operationInProgress,
              !startInProgress,
              !capturePermissionProbeInProgress,
              let current,
              current.phase == .running,
              let tap = current.tap
        else {
            return false
        }
        capturePermissionProbeInProgress = true
        defer { capturePermissionProbeInProgress = false }
        try await routeResources.verifyCapturePermission(using: tap)
        return true
    }

    func stop(bridgeGeneration: UInt64) async throws -> Bool {
        if let current, current.bridgeGeneration == bridgeGeneration {
            if operationInProgress, current.phase == .stopping {
                return false
            }
            try await stop()
            return true
        }
        guard formatRecoveryGuardBridgeGeneration == bridgeGeneration else { return false }
        try await stop()
        return true
    }

    private func checkStartCancellation() throws {
        try Task.checkCancellation()
        if startCancellationRequested {
            throw CancellationError()
        }
    }

    private func cleanup(
        _ resources: RouteResources,
        preserveTapAsFormatRecoveryGuard: Bool = false
    ) async throws {
        resources.phase = .stopping
        var firstError: (any Error)?
        _ = await retirementMaintenance.stop(bridgeGeneration: resources.bridgeGeneration)
        await runtimeAccess.discardPendingPrepared(bridgeGeneration: resources.bridgeGeneration)

        if let io = resources.io {
            do {
                try await audioIO.stop(io)
                try await audioIO.destroy(io)
                resources.io = nil
            } catch {
                firstError = error
            }
        }
        guard resources.io == nil else {
            resources.phase = .cleanupRequired
            if let firstError { throw firstError }
            return
        }

        if let runtime = resources.runtime {
            if resources.runtimeLeaseInstalled {
                guard let invalidated = await runtimeAccess.invalidate(
                    bridgeGeneration: resources.bridgeGeneration
                ), invalidated === runtime else {
                    throw M1AudioIOError.generationMismatch
                }
                resources.runtimeLeaseInstalled = false
            }
            runtimeFactory.destroyRuntime(runtime)
            resources.runtime = nil
        }
        if let aggregate = resources.aggregate {
            do {
                try await routeResources.destroyAggregate(aggregate)
                resources.aggregate = nil
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        guard resources.aggregate == nil else {
            resources.phase = .cleanupRequired
            if let firstError { throw firstError }
            return
        }
        if preserveTapAsFormatRecoveryGuard, let tap = resources.tap {
            formatRecoveryGuard = tap
            formatRecoveryGuardBridgeGeneration = resources.bridgeGeneration
            formatRecoveryGuardCleanupRequired = false
            resources.tap = nil
        }
        if let tap = resources.tap {
            do {
                try await routeResources.destroyTap(tap)
                resources.tap = nil
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if resources.tap == nil {
            do {
                try await routeResources.cleanupPendingResources()
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if resources.tap == nil, !(await routeResources.hasPendingResources()) {
            current = nil
        } else {
            resources.phase = .cleanupRequired
        }
        if let firstError { throw firstError }
    }

    private func destroyFormatRecoveryGuard() async throws {
        guard let guardResource = formatRecoveryGuard else { return }
        do {
            try await routeResources.destroyTap(guardResource)
            formatRecoveryGuard = nil
            formatRecoveryGuardBridgeGeneration = nil
            formatRecoveryGuardCleanupRequired = false
        } catch {
            formatRecoveryGuardCleanupRequired = true
            throw error
        }
    }
}

private func detachedValue<Value: Sendable>(
    operation: @escaping @Sendable () throws -> Value
) async throws -> Value {
    let task = Task.detached(operation: operation)
    let value = try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
    try Task.checkCancellation()
    return value
}
