import Foundation

struct AudioPipelineSnapshot: Equatable, Sendable {
    let generation: AudioGeneration
    let outputDeviceName: String
    let tapUID: String
    let tapFormat: String
    let diagnostics: AudioIOBridgeSnapshot
}

enum AudioLifecycleState: Equatable, Sendable {
    case stopped
    case starting(AudioGeneration)
    case running(AudioGeneration)
    case stopping(AudioGeneration)
    case shuttingDown(AudioGeneration?)
    case recoverableFailure(AudioGeneration?, String)
}

enum AudioPipelineError: Error, LocalizedError, Sendable {
    case alreadyRunning
    case operationInProgress(String)
    case startup(primary: String, cleanup: String?)
    case cleanup(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "An audio pipeline is already active."
        case let .operationInProgress(operation):
            return "The audio pipeline is already \(operation)."
        case let .startup(primary, cleanup):
            guard let cleanup else { return primary }
            return "\(primary) Cleanup also failed: \(cleanup)"
        case let .cleanup(message):
            return message
        }
    }
}

protocol AudioPipelineManaging: Sendable {
    func start(generation: AudioGeneration) async throws -> AudioPipelineSnapshot
    func stop() async throws
    func snapshot() async -> AudioPipelineSnapshot?
}

actor SystemAudioPipelineManager: AudioPipelineManaging {
    private enum OperationPhase: Equatable {
        case idle
        case starting(AudioGeneration)
        case running(AudioGeneration)
        case stopping(AudioGeneration?)
    }

    private struct Session {
        let generation: AudioGeneration
        let output: AudioDeviceSnapshot
        var tap: ProcessTapResource?
        var aggregate: AggregateDeviceResource?
        var io: AudioIOResource?
    }

    private let outputDiscovery: any DefaultOutputDeviceDiscovering
    private let tapController: any ProcessTapControlling
    private let aggregateController: any AggregateDeviceControlling
    private let ioController: any AudioIOControlling
    private let debugLogger: any AudioDebugLogging
    private let signalEvidenceRecorder: any AudioSignalEvidenceRecording
    private var session: Session?
    private var operationPhase: OperationPhase = .idle
    private var pendingAggregateCleanup = false
    private var pendingTapCleanup = false

    init(
        outputDiscovery: any DefaultOutputDeviceDiscovering = DefaultOutputDeviceDiscovery(),
        tapController: any ProcessTapControlling = ProcessTapController(),
        aggregateController: any AggregateDeviceControlling = AggregateDeviceController(),
        ioController: any AudioIOControlling = AudioIOController(),
        debugLogger: any AudioDebugLogging = AudioDebugLogger.shared,
        signalEvidenceRecorder: any AudioSignalEvidenceRecording = AudioSignalEvidenceRecorder.shared
    ) {
        self.outputDiscovery = outputDiscovery
        self.tapController = tapController
        self.aggregateController = aggregateController
        self.ioController = ioController
        self.debugLogger = debugLogger
        self.signalEvidenceRecorder = signalEvidenceRecorder
    }

    func start(generation: AudioGeneration) async throws -> AudioPipelineSnapshot {
        guard operationPhase == .idle else {
            throw AudioPipelineError.operationInProgress("starting or stopping")
        }
        guard session == nil else { throw AudioPipelineError.alreadyRunning }
        operationPhase = .starting(generation)

        var staleSession: Session?
        if let cleanupError = await cleanup(&staleSession) {
            operationPhase = .idle
            throw AudioPipelineError.cleanup(cleanupError)
        }

        var partial: Session?
        do {
            await debugLogger.log("pipeline.start", generation: generation, fields: [:])
            let output = try await outputDiscovery.snapshot(generation: generation)
            await debugLogger.log("output.selected", generation: generation, fields: [
                "objectID": "\(output.objectID)", "uid": output.uid, "name": output.name,
                "sampleRate": "\(output.nominalSampleRate)", "channels": "\(output.outputChannelCount)",
                "bufferFrames": "\(output.bufferFrameSize)",
                "bufferRange": "\(output.bufferFrameSizeRange.lowerBound)...\(output.bufferFrameSizeRange.upperBound)",
                "layout": output.outputLayout.buffers.map { "\($0.index):\($0.channelCount)" }.joined(separator: ",")
            ])
            partial = Session(generation: generation, output: output, tap: nil, aggregate: nil, io: nil)
            let createdTap = try await tapController.create(
                configuration: ProcessTapConfiguration(
                    generation: generation,
                    name: "EqualizerAU Minimal System Audio Tap",
                    muteBehavior: .muted,
                    outputDeviceUID: output.uid,
                    outputStreamIndex: 0
                )
            )
            partial?.tap = createdTap
            await debugLogger.log("tap.created", generation: generation, fields: [
                "objectID": "\(createdTap.objectID)", "uid": createdTap.uid,
                "sampleRate": "\(createdTap.format.mSampleRate)",
                "channels": "\(createdTap.format.mChannelsPerFrame)",
                "mute": "\(createdTap.muteBehavior)"
            ])
            let createdAggregate = try await aggregateController.create(
                configuration: AggregateDeviceConfiguration(generation: generation),
                output: output,
                tap: createdTap
            )
            partial?.aggregate = createdAggregate
            await debugLogger.log("aggregate.created", generation: generation, fields: [
                "objectID": "\(createdAggregate.objectID)", "uid": createdAggregate.uid,
                "tapUIDs": createdAggregate.tapUIDs.joined(separator: ","),
                "inputLayout": createdAggregate.inputLayout.buffers.map { "\($0.index):\($0.channelCount)" }.joined(separator: ",")
            ])
            var createdIO = try await ioController.create(
                aggregate: createdAggregate,
                tap: createdTap,
                output: output,
                maxFrames: max(try maximumFrameCapacity(output), createdAggregate.maximumFrames)
            )
            partial?.io = createdIO
            createdIO = try await ioController.startCapture(createdIO)
            partial?.io = createdIO
            createdIO = try await ioController.createOutput(createdIO)
            partial?.io = createdIO
            createdIO = try await ioController.startOutput(createdIO)
            partial?.io = createdIO
            session = partial
            await debugLogger.log("pipeline.running", generation: generation, fields: [:])
            let snapshot = try await makeSnapshot(session: session!)
            operationPhase = .running(generation)
            return snapshot
        } catch {
            let cleanupError = await cleanup(&partial)
            session = partial
            await debugLogger.log("pipeline.start.failed", generation: generation, fields: [
                "error": error.localizedDescription, "cleanupError": cleanupError ?? ""
            ])
            operationPhase = .idle
            throw AudioPipelineError.startup(
                primary: error.localizedDescription,
                cleanup: cleanupError
            )
        }
    }

    func stop() async throws {
        switch operationPhase {
        case .starting:
            throw AudioPipelineError.operationInProgress("starting")
        case .stopping:
            throw AudioPipelineError.operationInProgress("stopping")
        case .idle, .running:
            break
        }
        var current = session
        let generation = current?.generation
        operationPhase = .stopping(generation)
        await debugLogger.log("pipeline.stop", generation: generation, fields: [:])
        let cleanupError = await cleanup(&current)
        session = current
        if let cleanupError {
            await debugLogger.log("pipeline.stop.failed", generation: generation, fields: ["error": cleanupError])
            operationPhase = .idle
            throw AudioPipelineError.cleanup(cleanupError)
        }
        await debugLogger.log("pipeline.stopped", generation: generation, fields: [:])
        operationPhase = .idle
    }

    func snapshot() async -> AudioPipelineSnapshot? {
        guard case .running = operationPhase else { return nil }
        guard let session,
              session.tap != nil,
              session.aggregate != nil,
              session.io != nil
        else { return nil }
        do {
            return try await makeSnapshot(session: session)
        } catch {
            return nil
        }
    }

    func hasPendingResources() -> Bool {
        (session.map(hasResources) ?? false) || pendingAggregateCleanup || pendingTapCleanup
    }

    private func cleanup(_ session: inout Session?) async -> String? {
        var current = session
        var errors: [String] = []

        if let io = current?.io {
            do {
                let stopped = try await ioController.stop(io)
                current?.io = stopped
                try await ioController.destroy(stopped)
                current?.io = nil
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        if current?.io == nil, let aggregate = current?.aggregate {
            do {
                try await aggregateController.destroy(aggregate)
                current?.aggregate = nil
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        var aggregateDependenciesCleared = current?.io == nil && current?.aggregate == nil
        if aggregateDependenciesCleared {
            do {
                try await aggregateController.cleanupPendingCreation()
                pendingAggregateCleanup = false
            } catch {
                pendingAggregateCleanup = true
                aggregateDependenciesCleared = false
                errors.append(error.localizedDescription)
            }
        }
        if aggregateDependenciesCleared, let tap = current?.tap {
            do {
                try await tapController.destroy(tap)
                current?.tap = nil
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        if aggregateDependenciesCleared, current?.tap == nil {
            do {
                try await tapController.cleanupPendingCreation()
                pendingTapCleanup = false
            } catch {
                pendingTapCleanup = true
                errors.append(error.localizedDescription)
            }
        }
        if let current, hasResources(current) {
            session = current
        } else {
            session = nil
        }
        return errors.isEmpty ? nil : errors.joined(separator: " ")
    }

    private func makeSnapshot(session: Session) async throws -> AudioPipelineSnapshot {
        precondition(session.tap != nil && session.aggregate != nil && session.io != nil)
        let tap = session.tap!
        let io = session.io!
        let format = ProcessTapProbeResult(
            uid: tap.uid,
            sampleRate: tap.format.mSampleRate,
            channelCount: tap.format.mChannelsPerFrame,
            formatID: tap.format.mFormatID
        )
        let diagnostics = try await ioController.snapshot(io)
        let signalProbes = try await ioController.signalProbes(io)
        await signalEvidenceRecorder.record(
            windows: signalProbes,
            generation: session.generation,
            logger: debugLogger
        )
        await debugLogger.log("pipeline.snapshot", generation: session.generation, fields: [
            "captureCallbacks": "\(diagnostics.captureCallbackCount)",
            "outputCallbacks": "\(diagnostics.outputCallbackCount)",
            "capturedFrames": "\(diagnostics.capturedFrames)",
            "renderedFrames": "\(diagnostics.renderedFrames)",
            "capturedNonZero": "\(diagnostics.nonZeroSampleCount)",
            "renderedNonZero": "\(diagnostics.renderedNonZeroSampleCount)",
            "renderActionSilenceInputBlocks": "\(diagnostics.renderActionSilenceInputBlocks)",
            "renderActionSilenceClearedBlocks": "\(diagnostics.renderActionSilenceClearedBlocks)",
            "outputSilenceBlocks": "\(diagnostics.outputSilenceBlocks)",
            "outputNonSilenceBlocks": "\(diagnostics.outputNonSilenceBlocks)",
            "underruns": "\(diagnostics.underrunBlocks)", "overflowFrames": "\(diagnostics.overflowFrames)",
            "droppedFrames": "\(diagnostics.droppedFrames)", "ringFillFrames": "\(diagnostics.ringFillFrames)",
            "faultFlags": "0x\(String(diagnostics.faultFlags, radix: 16))",
            "captureHostTime": "\(diagnostics.lastHostTime)"
        ])
        guard ownsRunningSession(session) else {
            throw AudioIOError.staleResource
        }
        return AudioPipelineSnapshot(
            generation: session.generation,
            outputDeviceName: session.output.displayDescription,
            tapUID: tap.uid,
            tapFormat: format.formatDescription,
            diagnostics: diagnostics
        )
    }

    private func ownsRunningSession(_ expected: Session) -> Bool {
        let phaseMatches = switch operationPhase {
        case .starting(expected.generation), .running(expected.generation): true
        case .idle, .starting, .running, .stopping: false
        }
        guard phaseMatches, let current = session else { return false }
        return current.generation == expected.generation
            && current.tap?.ownershipToken == expected.tap?.ownershipToken
            && current.aggregate?.ownershipToken == expected.aggregate?.ownershipToken
            && current.io?.ownershipToken == expected.io?.ownershipToken
    }

    private func hasResources(_ session: Session) -> Bool {
        session.tap != nil || session.aggregate != nil || session.io != nil
    }

    private func maximumFrameCapacity(_ output: AudioDeviceSnapshot) throws -> UInt32 {
        let upper = output.bufferFrameSizeRange.upperBound.rounded(.up)
        guard upper.isFinite, upper > 0, upper <= Double(UInt32.max) else {
            throw AudioIOError.invalidFormat("output device frame-size range is invalid")
        }
        return max(output.bufferFrameSize, UInt32(upper))
    }
}

actor AudioLifecycleController {
    private let pipeline: any AudioPipelineManaging
    private(set) var state: AudioLifecycleState = .stopped
    private var generationValue: UInt64 = 0
    private var startTask: Task<AudioPipelineSnapshot, Error>?
    private var stopTask: Task<Void, Error>?

    init(pipeline: any AudioPipelineManaging = SystemAudioPipelineManager()) {
        self.pipeline = pipeline
    }

    func start() async throws -> AudioPipelineSnapshot {
        switch state {
        case .stopping, .shuttingDown:
            throw AudioPipelineError.operationInProgress("stopping")
        default:
            break
        }
        if case .running = state, let snapshot = await pipeline.snapshot() {
            return snapshot
        }
        if let startTask {
            return try await startTask.value
        }
        generationValue &+= 1
        let generation = AudioGeneration(rawValue: generationValue)
        state = .starting(generation)
        let task = Task { try await pipeline.start(generation: generation) }
        startTask = task
        do {
            let snapshot = try await task.value
            startTask = nil
            if state == .starting(generation) {
                state = .running(generation)
            }
            return snapshot
        } catch {
            startTask = nil
            if state == .starting(generation) {
                state = .recoverableFailure(generation, error.localizedDescription)
            }
            throw error
        }
    }

    func stop() async throws {
        if let stopTask {
            return try await stopTask.value
        }
        if state == .stopped { return }
        let generation = currentGeneration
        state = .stopping(generation ?? AudioGeneration(rawValue: generationValue))
        let pendingStart = startTask
        let task = Task {
            if let pendingStart { _ = try? await pendingStart.value }
            try await pipeline.stop()
        }
        stopTask = task
        do {
            try await task.value
            stopTask = nil
            startTask = nil
            state = .stopped
        } catch {
            stopTask = nil
            startTask = nil
            state = .recoverableFailure(generation, error.localizedDescription)
            throw error
        }
    }

    func snapshot() async -> AudioPipelineSnapshot? {
        await pipeline.snapshot()
    }

    func retry() async throws -> AudioPipelineSnapshot {
        try await stop()
        return try await start()
    }

    func shutdown() async throws {
        if let stopTask {
            return try await stopTask.value
        }
        state = .shuttingDown(currentGeneration)
        let pendingStart = startTask
        let task = Task {
            if let pendingStart { _ = try? await pendingStart.value }
            try await pipeline.stop()
        }
        stopTask = task
        do {
            try await task.value
            stopTask = nil
            startTask = nil
            state = .stopped
        } catch {
            stopTask = nil
            startTask = nil
            state = .recoverableFailure(currentGeneration, error.localizedDescription)
            throw error
        }
    }

    private var currentGeneration: AudioGeneration? {
        switch state {
        case let .starting(generation), let .running(generation), let .stopping(generation):
            return generation
        case let .shuttingDown(generation):
            return generation
        case let .recoverableFailure(generation, _):
            return generation
        case .stopped:
            return nil
        }
    }
}
