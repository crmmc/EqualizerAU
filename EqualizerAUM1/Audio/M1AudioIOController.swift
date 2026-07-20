import Foundation

final class M1RuntimeHandleLease: @unchecked Sendable {
    let bridgeGeneration: UInt64
    let pointer: OpaquePointer

    init(bridgeGeneration: UInt64, pointer: OpaquePointer) {
        self.bridgeGeneration = bridgeGeneration
        self.pointer = pointer
    }
}

final class M1AudioIOHostHandle: @unchecked Sendable {
    let identity = UUID()
    let pointer: OpaquePointer?

    init(pointer: OpaquePointer? = nil) {
        self.pointer = pointer
    }
}

final class M1CaptureHandle: @unchecked Sendable {
    let identity = UUID()
    let pointer: OpaquePointer?

    init(pointer: OpaquePointer? = nil) {
        self.pointer = pointer
    }
}

final class M1OutputHandle: @unchecked Sendable {
    let identity = UUID()
    let pointer: OpaquePointer?

    init(pointer: OpaquePointer? = nil) {
        self.pointer = pointer
    }
}

struct M1AudioIOHostConfiguration: Equatable, Sendable {
    let inputChannelCounts: [Int]
    let channelCount: Int
    let maximumFrameCount: Int
    let ringCapacityFrames: Int
    let primeFrames: Int
    let targetBacklogFrames: Int
}

struct M1OutputHostDiagnostics: Equatable, Sendable {
    let currentDeviceID: UInt32
    let currentDeviceUID: String
    let deviceSampleRate: Double
    let deviceChannelCount: Int
    let deviceFormatSupported: Bool
    let clientSampleRate: Double
    let clientChannelCount: Int
    let clientFormatSupported: Bool
    let maximumFrameCount: Int
    let isRunning: Bool
}

struct M1AudioIOHostCounters: Equatable, Sendable {
    let capturedFrames: UInt64
    let renderedFrames: UInt64
    let overflowedBlocks: UInt64
    let underrunBlocks: UInt64
    let droppedBacklogFrames: UInt64
    let invalidCallbacks: UInt64
    let overlappingRenderCallbacks: UInt64
}

final class M1RetainedOutputCreationError: Error, @unchecked Sendable {
    let output: M1OutputHandle
    let underlying: any Error

    init(output: M1OutputHandle, underlying: any Error) {
        self.output = output
        self.underlying = underlying
    }
}

enum M1AudioIOError: Error, Equatable, Sendable {
    case generationMismatch
    case invalidConfiguration(String)
    case invalidState(String)
    case staleResource
    case callbacksDidNotQuiesce
}

protocol M1AudioIOOperations: Sendable {
    func createHost(
        configuration: M1AudioIOHostConfiguration,
        runtime: M1RuntimeHandleLease
    ) throws -> M1AudioIOHostHandle
    func beginStopping(_ host: M1AudioIOHostHandle)
    func requestFadeOut(_ host: M1AudioIOHostHandle, frameCount: Int)
    func isFadeComplete(_ host: M1AudioIOHostHandle) -> Bool
    func isQuiescent(_ host: M1AudioIOHostHandle) -> Bool
    func hostDiagnostics(_ host: M1AudioIOHostHandle) throws -> M1AudioIOHostCounters
    func destroyHost(_ host: M1AudioIOHostHandle)

    func createCapture(aggregateDeviceID: UInt32, host: M1AudioIOHostHandle) throws -> M1CaptureHandle
    func startCapture(_ capture: M1CaptureHandle) throws
    func stopCapture(_ capture: M1CaptureHandle) throws
    func destroyCapture(_ capture: M1CaptureHandle) throws

    func createOutput(
        deviceID: UInt32,
        sampleRate: Double,
        channelCount: Int,
        maximumFrameCount: Int,
        host: M1AudioIOHostHandle
    ) throws -> M1OutputHandle
    func startOutput(_ output: M1OutputHandle) throws
    func stopOutput(_ output: M1OutputHandle) throws
    func outputDiagnostics(_ output: M1OutputHandle) throws -> M1OutputHostDiagnostics
    func destroyOutput(_ output: M1OutputHandle) throws
}

struct M1AudioIOControlTiming: Sendable {
    let pollIntervalNanoseconds: UInt64
    let fadeDeadlineNanoseconds: UInt64
    let quiescenceDeadlineNanoseconds: UInt64
    let nowNanoseconds: @Sendable () async -> UInt64
    let sleep: @Sendable (UInt64) async throws -> Void

    init(
        pollIntervalNanoseconds: UInt64 = 1_000_000,
        fadeDeadlineNanoseconds: UInt64 = 200_000_000,
        quiescenceDeadlineNanoseconds: UInt64 = 100_000_000,
        nowNanoseconds: @escaping @Sendable () async -> UInt64,
        sleep: @escaping @Sendable (UInt64) async throws -> Void
    ) {
        precondition(pollIntervalNanoseconds > 0)
        precondition(fadeDeadlineNanoseconds >= pollIntervalNanoseconds)
        precondition(quiescenceDeadlineNanoseconds >= pollIntervalNanoseconds)
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.fadeDeadlineNanoseconds = fadeDeadlineNanoseconds
        self.quiescenceDeadlineNanoseconds = quiescenceDeadlineNanoseconds
        self.nowNanoseconds = nowNanoseconds
        self.sleep = sleep
    }
}

struct M1AudioIOResource: Sendable {
    let ownershipToken: UUID
    let generation: M1AudioRouteGeneration
    let bridgeGeneration: UInt64
    let host: M1AudioIOHostHandle
    let capture: M1CaptureHandle
    let runtime: M1RuntimeHandleLease
}

actor M1AudioIOController {
    private final class State: @unchecked Sendable {
        let resource: M1AudioIOResource
        let outputSnapshot: M1OutputDeviceSnapshot
        var output: M1OutputHandle?
        var capture: M1CaptureHandle?
        var captureStarted = false
        var outputStarted = false
        var operationInProgress = false

        init(resource: M1AudioIOResource, outputSnapshot: M1OutputDeviceSnapshot) {
            self.resource = resource
            self.outputSnapshot = outputSnapshot
            capture = resource.capture
        }
    }

    private let operations: any M1AudioIOOperations
    private let timing: M1AudioIOControlTiming
    private var states: [UUID: State] = [:]

    init(operations: any M1AudioIOOperations, timing: M1AudioIOControlTiming) {
        self.operations = operations
        self.timing = timing
    }

    func create(
        generation: M1AudioRouteGeneration,
        bridgeGeneration: UInt64,
        aggregate: M1AggregateResource,
        output: M1OutputDeviceSnapshot,
        runtime: M1RuntimeHandleLease
    ) throws -> M1AudioIOResource {
        guard generation == aggregate.descriptor.generation,
              generation == output.generation,
              bridgeGeneration == runtime.bridgeGeneration
        else {
            throw M1AudioIOError.generationMismatch
        }
        let channelCount = output.layout.channels.count
        guard channelCount > 0,
              aggregate.format.channelCount == UInt32(channelCount),
              aggregate.format.sampleRate == output.layout.sampleRate,
              aggregate.maximumFrameCount >= output.layout.maximumFrameCount
        else {
            throw M1AudioIOError.invalidConfiguration("aggregate and output formats do not match")
        }
        let maximumFrames = aggregate.maximumFrameCount
        let (ringCapacity, overflow) = maximumFrames.multipliedReportingOverflow(by: 8)
        guard !overflow, ringCapacity > 0 else {
            throw M1AudioIOError.invalidConfiguration("ring capacity overflow")
        }
        let primeFrames = min(ringCapacity, output.layout.maximumFrameCount * 2)
        let configuration = M1AudioIOHostConfiguration(
            inputChannelCounts: aggregate.bufferChannelCounts,
            channelCount: channelCount,
            maximumFrameCount: maximumFrames,
            ringCapacityFrames: ringCapacity,
            primeFrames: primeFrames,
            targetBacklogFrames: max(maximumFrames, primeFrames)
        )
        let host = try operations.createHost(configuration: configuration, runtime: runtime)
        do {
            let capture = try operations.createCapture(
                aggregateDeviceID: aggregate.descriptor.objectID,
                host: host
            )
            let resource = M1AudioIOResource(
                ownershipToken: UUID(),
                generation: generation,
                bridgeGeneration: bridgeGeneration,
                host: host,
                capture: capture,
                runtime: runtime
            )
            states[resource.ownershipToken] = State(resource: resource, outputSnapshot: output)
            return resource
        } catch {
            operations.destroyHost(host)
            throw error
        }
    }

    func startCapture(_ resource: M1AudioIOResource) throws {
        let state = try begin(resource)
        defer { finish(state) }
        if !state.captureStarted {
            guard let capture = state.capture else {
                throw M1AudioIOError.staleResource
            }
            try operations.startCapture(capture)
            state.captureStarted = true
        }
    }

    func createOutput(_ resource: M1AudioIOResource) throws {
        let state = try begin(resource)
        defer { finish(state) }
        guard state.captureStarted else {
            throw M1AudioIOError.invalidState("capture must be running before output creation")
        }
        guard state.output == nil else { return }
        let output: M1OutputHandle
        do {
            output = try operations.createOutput(
                deviceID: state.outputSnapshot.objectID,
                sampleRate: state.outputSnapshot.layout.sampleRate,
                channelCount: state.outputSnapshot.layout.channels.count,
                maximumFrameCount: state.resource.runtime.bridgeGeneration == resource.bridgeGeneration
                    ? state.outputSnapshot.layout.maximumFrameCount
                    : 0,
                host: resource.host
            )
        } catch let retained as M1RetainedOutputCreationError {
            state.output = retained.output
            throw retained.underlying
        }
        state.output = output
        do {
            let diagnostics = try operations.outputDiagnostics(output)
            try validateOutput(diagnostics, snapshot: state.outputSnapshot, requireRunning: false)
        } catch {
            do {
                try operations.destroyOutput(output)
                state.output = nil
                throw error
            } catch let cleanupError {
                throw cleanupError
            }
        }
    }

    func startOutput(_ resource: M1AudioIOResource) throws {
        let state = try begin(resource)
        defer { finish(state) }
        guard state.captureStarted, let output = state.output else {
            throw M1AudioIOError.invalidState("capture and output registration are required")
        }
        if !state.outputStarted {
            try operations.startOutput(output)
            state.outputStarted = true
        }
        do {
            let diagnostics = try operations.outputDiagnostics(output)
            try validateOutput(diagnostics, snapshot: state.outputSnapshot, requireRunning: true)
        } catch {
            do {
                try operations.stopOutput(output)
                state.outputStarted = false
                throw error
            } catch let cleanupError {
                throw cleanupError
            }
        }
    }

    func diagnostics(_ resource: M1AudioIOResource) throws -> M1AudioIOHostCounters {
        guard let state = states[resource.ownershipToken],
              state.resource.host === resource.host,
              state.resource.runtime === resource.runtime
        else {
            throw M1AudioIOError.staleResource
        }
        return try operations.hostDiagnostics(resource.host)
    }

    func stop(_ resource: M1AudioIOResource) async throws {
        let state = try begin(resource)
        defer { finish(state) }
        if state.outputStarted, let output = state.output {
            operations.requestFadeOut(resource.host, frameCount: 512)
            _ = await waitUntil(
                deadline: timing.fadeDeadlineNanoseconds,
                predicate: { self.operations.isFadeComplete(resource.host) }
            )
            do {
                try operations.stopOutput(output)
                state.outputStarted = false
            } catch {
                throw error
            }
        }
        if state.captureStarted {
            guard let capture = state.capture else {
                throw M1AudioIOError.staleResource
            }
            do {
                try operations.stopCapture(capture)
                state.captureStarted = false
            } catch {
                throw error
            }
        }
        operations.beginStopping(resource.host)
    }

    func destroy(_ resource: M1AudioIOResource) async throws {
        let state = try begin(resource)
        defer { finish(state) }
        guard !state.outputStarted, !state.captureStarted else {
            throw M1AudioIOError.invalidState("capture and output must be stopped before destroy")
        }
        operations.beginStopping(resource.host)
        if let output = state.output {
            try operations.destroyOutput(output)
            state.output = nil
        }
        if let capture = state.capture {
            try operations.destroyCapture(capture)
            state.capture = nil
        }
        let quiescent = await waitUntil(
            deadline: timing.quiescenceDeadlineNanoseconds,
            predicate: { self.operations.isQuiescent(resource.host) }
        )
        guard quiescent else { throw M1AudioIOError.callbacksDidNotQuiesce }
        operations.destroyHost(resource.host)
        states.removeValue(forKey: resource.ownershipToken)
    }

    private func begin(_ resource: M1AudioIOResource) throws -> State {
        guard let state = states[resource.ownershipToken],
              state.resource.host === resource.host,
              state.resource.capture === resource.capture,
              state.resource.runtime === resource.runtime,
              !state.operationInProgress
        else {
            throw M1AudioIOError.staleResource
        }
        state.operationInProgress = true
        return state
    }

    private func finish(_ state: State) {
        if states[state.resource.ownershipToken] === state {
            state.operationInProgress = false
        }
    }

    private func validateOutput(
        _ diagnostics: M1OutputHostDiagnostics,
        snapshot: M1OutputDeviceSnapshot,
        requireRunning: Bool
    ) throws {
        guard diagnostics.currentDeviceID == snapshot.objectID,
              diagnostics.currentDeviceUID == snapshot.uid,
              diagnostics.deviceSampleRate == snapshot.layout.sampleRate,
              diagnostics.deviceChannelCount == snapshot.layout.channels.count,
              diagnostics.deviceFormatSupported,
              diagnostics.clientSampleRate == snapshot.layout.sampleRate,
              diagnostics.clientChannelCount == snapshot.layout.channels.count,
              diagnostics.clientFormatSupported,
              diagnostics.maximumFrameCount >= snapshot.layout.maximumFrameCount,
              !requireRunning || diagnostics.isRunning
        else {
            throw M1AudioIOError.invalidConfiguration("output readback does not match the discovery generation")
        }
    }

    private func waitUntil(
        deadline: UInt64,
        predicate: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let start = await timing.nowNanoseconds()
        while !predicate() {
            let now = await timing.nowNanoseconds()
            let elapsed = now >= start ? now - start : UInt64.max
            if elapsed >= deadline { return false }
            do {
                try await timing.sleep(timing.pollIntervalNanoseconds)
            } catch {
                return false
            }
        }
        return true
    }
}
