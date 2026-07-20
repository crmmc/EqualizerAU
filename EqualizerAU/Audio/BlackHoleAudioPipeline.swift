import Foundation

struct BlackHoleAudioPipelineSnapshot: Equatable, Sendable {
    let generation: AudioGeneration
    let physicalOutputName: String
    let virtualDeviceName: String
    let routeActive: Bool
    let diagnostics: AudioIOBridgeSnapshot
}

enum BlackHoleAudioPipelineError: Error, Equatable, LocalizedError, Sendable {
    case alreadyRunning
    case invalidPhysicalOutput(String)
    case capturePreflightTimedOut
    case captureReadinessTimedOut
    case outputReadinessTimedOut
    case realtimeFault(UInt32)
    case startup(primary: String, cleanup: String?)
    case cleanup(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "A BlackHole audio pipeline is already active."
        case let .invalidPhysicalOutput(reason):
            return "The saved physical output is invalid: \(reason)."
        case .capturePreflightTimedOut:
            return "The BlackHole capture endpoint did not produce a callback before route activation."
        case .captureReadinessTimedOut:
            return "BlackHole capture did not produce the required callback backlog before the bounded deadline."
        case .outputReadinessTimedOut:
            return "The explicit physical HALOutput did not begin rendering before the bounded deadline."
        case let .realtimeFault(flags):
            return "The BlackHole route reported realtime fault flags 0x\(String(flags, radix: 16))."
        case let .startup(primary, cleanup):
            guard let cleanup else { return primary }
            return "\(primary) Cleanup also failed: \(cleanup)"
        case let .cleanup(message):
            return message
        }
    }
}

protocol BlackHoleAudioPipelineManaging: Sendable {
    func start(generation: AudioGeneration) async throws -> BlackHoleAudioPipelineSnapshot
    func stop() async throws
    func snapshot() async -> BlackHoleAudioPipelineSnapshot?
}

enum BlackHoleAudioLifecycleState: Equatable, Sendable {
    case stopped
    case starting(AudioGeneration)
    case running(AudioGeneration)
    case stopping(AudioGeneration?)
    case recoverableFailure(AudioGeneration?, String)
}

actor BlackHoleAudioLifecycleController {
    private let pipeline: any BlackHoleAudioPipelineManaging
    private(set) var state: BlackHoleAudioLifecycleState = .stopped
    private var generationValue: UInt64 = 0
    private var startTask: Task<BlackHoleAudioPipelineSnapshot, Error>?

    init(pipeline: any BlackHoleAudioPipelineManaging = BlackHoleAudioPipeline()) {
        self.pipeline = pipeline
    }

    func start() async throws -> BlackHoleAudioPipelineSnapshot {
        if case .running = state, let snapshot = await pipeline.snapshot() {
            return snapshot
        }
        if let startTask { return try await startTask.value }

        generationValue &+= 1
        let generation = AudioGeneration(rawValue: generationValue)
        state = .starting(generation)
        let task = Task { try await pipeline.start(generation: generation) }
        startTask = task
        do {
            let snapshot = try await task.value
            startTask = nil
            if state == .starting(generation) { state = .running(generation) }
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
        if state == .stopped { return }
        let generation = currentGeneration
        state = .stopping(generation)
        if let startTask {
            _ = try? await startTask.value
            self.startTask = nil
        }
        do {
            try await pipeline.stop()
            state = .stopped
        } catch {
            state = .recoverableFailure(generation, error.localizedDescription)
            throw error
        }
    }

    func snapshot() async -> BlackHoleAudioPipelineSnapshot? {
        await pipeline.snapshot()
    }

    private var currentGeneration: AudioGeneration? {
        switch state {
        case let .starting(generation), let .running(generation): return generation
        case let .stopping(generation), let .recoverableFailure(generation, _): return generation
        case .stopped: return nil
        }
    }
}

actor BlackHoleAudioPipeline: BlackHoleAudioPipelineManaging {
    private struct Session: Sendable {
        let generation: AudioGeneration
        let physicalOutput: AudioDeviceSnapshot
        let blackHole: BlackHoleDeviceSnapshot
        var io: BlackHoleAudioIOResource?
        var route: DefaultAudioRouteResource?
    }

    private let outputDiscovery: any DefaultOutputDeviceDiscovering
    private let blackHoleDiscovery: any BlackHoleDeviceDiscovering
    private let routeController: any DefaultAudioRouteControlling
    private let ioController: any BlackHoleAudioIOControlling
    private let debugLogger: any AudioDebugLogging
    private let readinessDelay: @Sendable (Duration) async throws -> Void
    private let readinessAttempts: Int
    private var session: Session?

    init(
        outputDiscovery: any DefaultOutputDeviceDiscovering = DefaultOutputDeviceDiscovery(),
        blackHoleDiscovery: any BlackHoleDeviceDiscovering = BlackHoleDeviceDiscovery(),
        routeController: any DefaultAudioRouteControlling = DefaultAudioRouteController(),
        ioController: any BlackHoleAudioIOControlling = BlackHoleAudioIOController(),
        debugLogger: any AudioDebugLogging = AudioDebugLogger.shared,
        readinessAttempts: Int = 100,
        readinessDelay: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.outputDiscovery = outputDiscovery
        self.blackHoleDiscovery = blackHoleDiscovery
        self.routeController = routeController
        self.ioController = ioController
        self.debugLogger = debugLogger
        self.readinessAttempts = readinessAttempts
        self.readinessDelay = readinessDelay
    }

    func start(generation: AudioGeneration) async throws -> BlackHoleAudioPipelineSnapshot {
        guard session == nil else { throw BlackHoleAudioPipelineError.alreadyRunning }

        var partial: Session?
        do {
            await debugLogger.log("blackhole.pipeline.start", generation: generation, fields: [:])
            try await routeController.recoverIfNeeded()

            let physicalOutput = try await outputDiscovery.snapshot(generation: generation)
            guard physicalOutput.uid != BlackHoleDeviceSnapshot.expectedUID else {
                throw BlackHoleAudioPipelineError.invalidPhysicalOutput(
                    "the current default is already BlackHole and no recoverable original route is available"
                )
            }
            let blackHole = try await blackHoleDiscovery.snapshot(generation: generation)
            partial = Session(
                generation: generation,
                physicalOutput: physicalOutput,
                blackHole: blackHole,
                io: nil,
                route: nil
            )

            await debugLogger.log("blackhole.pipeline.devices", generation: generation, fields: [
                "physicalDevice": "\(physicalOutput.objectID)",
                "physicalUID": physicalOutput.uid,
                "physicalName": physicalOutput.name,
                "blackHoleDevice": "\(blackHole.objectID)",
                "blackHoleUID": blackHole.uid,
                "sampleRate": "\(blackHole.nominalSampleRate)"
            ])

            let maximumFrames = try maximumFrameCapacity(physicalOutput)
            var io = try await ioController.create(
                blackHole: blackHole,
                physicalOutput: physicalOutput,
                maximumFrames: maximumFrames
            )
            partial?.io = io

            io = try await ioController.startOutput(io)
            partial?.io = io
            try await waitForOutputReadiness(io)
            io = try await ioController.stopOutput(io)
            partial?.io = io

            io = try await ioController.startCapture(io)
            partial?.io = io
            try await waitForCapturePreflight(io)
            io = try await ioController.stopCapture(io)
            partial?.io = io
            try await ioController.reset(io)

            let route = try await routeController.activate(
                virtualDevice: blackHole,
                generation: generation
            )
            partial?.route = route
            await debugLogger.log("blackhole.route.activated", generation: generation, fields: [
                "virtualUID": blackHole.uid,
                "originalOutputUID": route.journal.originalOutputDeviceUID,
                "originalSystemOutputUID": route.journal.originalSystemOutputDeviceUID
            ])

            io = try await ioController.startCapture(io)
            partial?.io = io
            try await waitForCaptureReadiness(
                io,
                requiredBacklog: min(maximumFrames * 2, physicalOutput.bufferFrameSize * 2)
            )

            io = try await ioController.startOutput(io)
            partial?.io = io
            try await waitForOutputReadiness(io)

            session = partial
            await debugLogger.log("blackhole.pipeline.running", generation: generation, fields: [:])
            return await makeSnapshot(session!)
        } catch {
            let cleanupError = await cleanup(&partial)
            session = partial
            await debugLogger.log("blackhole.pipeline.start.failed", generation: generation, fields: [
                "error": error.localizedDescription,
                "cleanupError": cleanupError ?? ""
            ])
            throw BlackHoleAudioPipelineError.startup(
                primary: error.localizedDescription,
                cleanup: cleanupError
            )
        }
    }

    func stop() async throws {
        guard session != nil else { return }
        var current = session
        let generation = current?.generation
        await debugLogger.log("blackhole.pipeline.stop", generation: generation, fields: [:])
        let cleanupError = await cleanup(&current)
        session = current
        if let cleanupError {
            await debugLogger.log(
                "blackhole.pipeline.stop.failed",
                generation: generation,
                fields: ["error": cleanupError]
            )
            throw BlackHoleAudioPipelineError.cleanup(cleanupError)
        }
        await debugLogger.log("blackhole.pipeline.stopped", generation: generation, fields: [:])
    }

    func snapshot() async -> BlackHoleAudioPipelineSnapshot? {
        guard let session, session.route != nil, session.io != nil else { return nil }
        return await makeSnapshot(session)
    }

    func hasPendingResources() -> Bool {
        session.map(hasResources) ?? false
    }

    private func waitForCaptureReadiness(
        _ io: BlackHoleAudioIOResource,
        requiredBacklog: UInt32
    ) async throws {
        for _ in 0..<readinessAttempts {
            let diagnostics = await ioController.snapshot(io)
            try validateRealtimeFaults(diagnostics)
            if diagnostics.captureCallbackCount >= 2,
               diagnostics.capturedFrames >= UInt64(requiredBacklog),
               diagnostics.ringFillFrames >= requiredBacklog {
                return
            }
            try await readinessDelay(.milliseconds(10))
        }
        throw BlackHoleAudioPipelineError.captureReadinessTimedOut
    }

    private func waitForCapturePreflight(
        _ io: BlackHoleAudioIOResource
    ) async throws {
        for _ in 0..<readinessAttempts {
            let diagnostics = await ioController.snapshot(io)
            try validateRealtimeFaults(diagnostics)
            if diagnostics.captureCallbackCount > 0,
               diagnostics.capturedFrames > 0,
               diagnostics.lastHostTime > 0 {
                return
            }
            try await readinessDelay(.milliseconds(10))
        }
        throw BlackHoleAudioPipelineError.capturePreflightTimedOut
    }

    private func waitForOutputReadiness(_ io: BlackHoleAudioIOResource) async throws {
        for _ in 0..<readinessAttempts {
            let diagnostics = await ioController.snapshot(io)
            try validateRealtimeFaults(diagnostics)
            if diagnostics.outputCallbackCount > 0 { return }
            try await readinessDelay(.milliseconds(10))
        }
        throw BlackHoleAudioPipelineError.outputReadinessTimedOut
    }

    private func validateRealtimeFaults(_ diagnostics: AudioIOBridgeSnapshot) throws {
        guard diagnostics.faultFlags == 0 else {
            throw BlackHoleAudioPipelineError.realtimeFault(diagnostics.faultFlags)
        }
    }

    private func cleanup(_ session: inout Session?) async -> String? {
        guard var current = session else { return nil }
        var errors: [String] = []

        if let io = current.io, current.route != nil, io.isOutputStarted {
            do {
                try await ioController.fadeOut(io)
            } catch {
                errors.append("Fade physical output: \(error.localizedDescription)")
            }
        }

        // Restore user routing while the processed path is faded. If restoration fails,
        // resume the chain and retain every dependency for an explicit retry.
        if let route = current.route {
            do {
                try await routeController.restore(route)
                current.route = nil
            } catch {
                if let io = current.io, io.isOutputStarted {
                    await ioController.cancelFadeOut(io)
                }
                errors.append("Restore default audio route: \(error.localizedDescription)")
                session = current
                return errors.joined(separator: " ")
            }
        }

        if var io = current.io {
            if io.isOutputStarted {
                do {
                    io = try await ioController.stopOutput(io)
                    current.io = io
                } catch {
                    errors.append("Stop physical output: \(error.localizedDescription)")
                }
            }
            if io.isCaptureStarted {
                do {
                    io = try await ioController.stopCapture(io)
                    current.io = io
                } catch {
                    errors.append("Stop BlackHole capture: \(error.localizedDescription)")
                }
            }
            if !io.isOutputStarted, !io.isCaptureStarted {
                do {
                    try await ioController.destroy(io)
                    current.io = nil
                } catch {
                    errors.append("Destroy BlackHole IO: \(error.localizedDescription)")
                }
            }
        }

        session = hasResources(current) ? current : nil
        return errors.isEmpty ? nil : errors.joined(separator: " ")
    }

    private func makeSnapshot(_ session: Session) async -> BlackHoleAudioPipelineSnapshot {
        precondition(session.io != nil)
        return BlackHoleAudioPipelineSnapshot(
            generation: session.generation,
            physicalOutputName: session.physicalOutput.displayDescription,
            virtualDeviceName: session.blackHole.name,
            routeActive: session.route != nil,
            diagnostics: await ioController.snapshot(session.io!)
        )
    }

    private func hasResources(_ session: Session) -> Bool {
        session.io != nil || session.route != nil
    }

    private func maximumFrameCapacity(_ output: AudioDeviceSnapshot) throws -> UInt32 {
        let upper = output.bufferFrameSizeRange.upperBound.rounded(.up)
        guard upper.isFinite, upper > 0, upper <= Double(UInt32.max / 8) else {
            throw BlackHoleAudioPipelineError.invalidPhysicalOutput(
                "buffer frame-size range is invalid"
            )
        }
        return max(output.bufferFrameSize, UInt32(upper))
    }
}
