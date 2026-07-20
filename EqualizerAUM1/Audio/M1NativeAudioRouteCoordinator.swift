import Foundation

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
    let linearGainsByChannel: [Float]
    let bufferChannelCounts: [Int]
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
    private var current: RouteResources?
    private var nextGeneration: UInt64 = 0
    private var nextBridgeGeneration: UInt64 = 0
    private var operationInProgress = false
    private var startInProgress = false
    private var startCancellationRequested = false

    init(
        routeResources: M1AudioRouteResourceController,
        audioIO: M1AudioIOController,
        runtimeFactory: any M1RuntimeCreating,
        runtimeAccess: M1RuntimeLeaseAccess,
        retirementMaintenance: M1RetirementMaintenanceCoordinator
    ) {
        self.routeResources = routeResources
        self.audioIO = audioIO
        self.runtimeFactory = runtimeFactory
        self.runtimeAccess = runtimeAccess
        self.retirementMaintenance = retirementMaintenance
    }

    func state() -> M1NativeAudioRouteState {
        guard let current else { return .stopped }
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
            let output = try await routeResources.discoverOutput(generation: resources.generation)
            resources.output = output
            try checkStartCancellation()
            let tap = try await routeResources.createTap(
                generation: resources.generation,
                output: output
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
            let compiled = try await Task.detached {
                try M1ProcessingBuilder.build(nodes: configuration.nodes, layout: output.layout)
            }.value
            try checkStartCancellation()
            let runtime = try runtimeFactory.createRuntime(
                bridgeGeneration: resources.bridgeGeneration,
                initialState: M1RuntimeInitialState(
                    linearGainsByChannel: compiled.linearGainsByChannel,
                    bufferChannelCounts: output.layout.bufferChannelCounts,
                    effectsEnabled: configuration.effectsEnabled
                ),
                maximumFrameCount: aggregate.maximumFrameCount,
                sampleRate: output.layout.sampleRate
            )
            resources.runtime = runtime
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
                runtime: runtime
            )
            resources.io = io
            try checkStartCancellation()
            try await audioIO.startCapture(io)
            try checkStartCancellation()
            try await audioIO.createOutput(io)
            try checkStartCancellation()
            try await audioIO.startOutput(io)
            try checkStartCancellation()
            resources.phase = .running
        } catch {
            try? await cleanup(resources)
            throw error
        }
    }

    func outputLayout() -> M1OutputLayoutSnapshot? {
        guard current?.phase == .running else { return nil }
        return current?.output?.layout
    }

    func prepare(configuration: M1ConfigurationSnapshot) async throws -> M1AudioConfigurationPreparation {
        if let current, current.phase == .running, let output = current.output {
            let compiled = try await Task.detached {
                try M1ProcessingBuilder.build(nodes: configuration.nodes, layout: output.layout)
            }.value
            guard self.current === current, current.phase == .running else {
                return .waitingForOutput
            }
            return M1AudioConfigurationPreparation(
                layout: output.layout,
                compiled: compiled,
                bridgeGeneration: current.bridgeGeneration
            )
        }
        guard current == nil, !operationInProgress, nextGeneration < UInt64.max else {
            return .waitingForOutput
        }
        do {
            let discoveryGeneration = M1AudioRouteGeneration(rawValue: nextGeneration + 1)
            let output = try await routeResources.discoverOutput(generation: discoveryGeneration)
            let compiled = try await Task.detached {
                try M1ProcessingBuilder.build(nodes: configuration.nodes, layout: output.layout)
            }.value
            guard current == nil, !operationInProgress else { return .waitingForOutput }
            return M1AudioConfigurationPreparation(
                layout: output.layout,
                compiled: compiled,
                bridgeGeneration: nil
            )
        } catch let error as M1ProcessingBuildError {
            throw error
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
                linearGainsByChannel: compiled.linearGainsByChannel,
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

    func stop() async throws {
        if startInProgress {
            startCancellationRequested = true
            while startInProgress {
                await Task.yield()
            }
        }
        guard let current else { return }
        guard !operationInProgress else {
            throw M1AudioIOError.invalidState("route operation is already in progress")
        }
        operationInProgress = true
        defer { operationInProgress = false }
        try await cleanup(current)
    }

    func stop(bridgeGeneration: UInt64) async throws {
        guard current?.bridgeGeneration == bridgeGeneration else { return }
        try await stop()
    }

    private func checkStartCancellation() throws {
        if startCancellationRequested {
            throw CancellationError()
        }
    }

    private func cleanup(_ resources: RouteResources) async throws {
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
}
