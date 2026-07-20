import Foundation

protocol M1RuntimeCreating: Sendable {
    func createRuntime(
        bridgeGeneration: UInt64,
        channelCount: Int,
        maximumFrameCount: Int,
        sampleRate: Double
    ) throws -> M1RuntimeHandleLease
    func destroyRuntime(_ runtime: M1RuntimeHandleLease)
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
        guard current == nil, !operationInProgress else {
            throw M1AudioIOError.invalidState("route is already active or changing")
        }
        operationInProgress = true
        defer { operationInProgress = false }
        try await routeResources.cleanupPendingResources()
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
            let tap = try await routeResources.createTap(
                generation: resources.generation,
                output: output
            )
            resources.tap = tap
            let aggregate = try await routeResources.createAggregate(
                generation: resources.generation,
                output: output,
                tap: tap
            )
            resources.aggregate = aggregate
            let runtime = try runtimeFactory.createRuntime(
                bridgeGeneration: resources.bridgeGeneration,
                channelCount: output.layout.channels.count,
                maximumFrameCount: aggregate.maximumFrameCount,
                sampleRate: output.layout.sampleRate
            )
            resources.runtime = runtime
            guard await runtimeAccess.install(runtime) else {
                throw M1AudioIOError.invalidState("runtime lease is already installed")
            }
            resources.runtimeLeaseInstalled = true
            let io = try await audioIO.create(
                generation: resources.generation,
                bridgeGeneration: resources.bridgeGeneration,
                aggregate: aggregate,
                output: output,
                runtime: runtime
            )
            resources.io = io
            try await audioIO.startCapture(io)
            try await audioIO.createOutput(io)
            try await audioIO.startOutput(io)
            resources.phase = .running
        } catch {
            try? await cleanup(resources)
            throw error
        }
    }

    func stop() async throws {
        guard let current, !operationInProgress else {
            if self.current == nil { return }
            throw M1AudioIOError.invalidState("route operation is already in progress")
        }
        operationInProgress = true
        defer { operationInProgress = false }
        try await cleanup(current)
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
