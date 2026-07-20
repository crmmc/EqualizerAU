import CoreAudio
import Foundation

enum AudioOutputIsolationPhase: String, Codable, Equatable, Sendable {
    case mutedSelfExcludingTap
}

struct AudioOutputIsolationToneSnapshot: Equatable, Sendable {
    let callbackCount: UInt64
    let renderedFrames: UInt64
    let nonZeroSampleCount: UInt64
    let lastHostTime: UInt64
    let maxObservedFrames: UInt32
    let faultFlags: UInt32
    let silenceBlocks: UInt64
    let nonSilenceBlocks: UInt64
    let completed: Bool
}

struct AudioOutputIsolationDrainSnapshot: Equatable, Sendable {
    let callbackCount: UInt64
    let capturedFrames: UInt64
    let nonZeroSampleCount: UInt64
    let lastHostTime: UInt64
    let maxObservedFrames: UInt32
    let faultFlags: UInt32
}

enum AudioOutputIsolationSignalPhase: String, Codable, Equatable, Sendable {
    case challengeCapture
}

struct AudioOutputIsolationChallenge: Equatable, Sendable {
    let seed: UInt64
    let sampleRate: Double
    let carrierFrequencyHz: Double
    let amplitude: Float
    let chipFrames: UInt32
    let samples: [Float]
}

struct AudioOutputIsolationSignalWindow: Equatable, Sendable {
    let phase: AudioOutputIsolationSignalPhase
    let sequence: UInt64
    let firstHostTime: UInt64
    let droppedFrames: UInt64
    let frameCount: UInt32
    let channelCount: UInt32
    let sampleRate: Double
    let samples: [Float]
}

struct AudioOutputIsolationSignalAnalysis: Codable, Equatable, Sendable {
    let phase: AudioOutputIsolationSignalPhase
    let sequence: UInt64
    let firstHostTime: UInt64
    let droppedFrames: UInt64
    let frameCount: UInt32
    let channelCount: UInt32
    let sampleRate: Double
    let rms: Double
    let rmsDBFS: Double
    let peak: Double
    let peakDBFS: Double
    let challengeCorrelation: Double
    let challengeLagFrames: Int64
    let challengeComparedFrames: UInt32
    let estimatedGain: Double
    let estimatedGainDB: Double
}

enum AudioOutputIsolationRecaptureVerdict: String, Codable, Equatable, Sendable {
    case detected
    case notDetected
    case inconclusive
}

struct AudioOutputIsolationAttribution: Codable, Equatable, Sendable {
    let capture: AudioOutputIsolationSignalAnalysis
    let challengeSeed: UInt64
    let challengeCarrierFrequencyHz: Double
    let challengeFrameCount: UInt32
    let correlationThreshold: Double
    let minimumEstimatedGain: Double
    let drainFaultFlags: UInt32
    let verdict: AudioOutputIsolationRecaptureVerdict
    let reason: String
}

struct AudioOutputIsolationProcessIdentity: Equatable, Sendable {
    let tapCreation: AudioObjectID
    let afterOutputInitialization: AudioObjectID
    let afterFirstRender: AudioObjectID
    let outputOwnershipAfterFirstRender: CoreAudioProcessOutputState
    let activeOutputProcessesBeforeTap: [AudioObjectID]
    let activeOutputProcessesAfterFirstRender: [AudioObjectID]
    let activeOutputProcessesBeforeStop: [AudioObjectID]
}

struct AudioOutputIsolationToneDiagnostics: Sendable {
    let componentSubType: OSType
    let currentDevice: AudioObjectID
    let deviceFormat: AudioStreamBasicDescription
    let clientFormat: AudioStreamBasicDescription
    let maximumFrames: UInt32
}

struct AudioOutputIsolationPhaseResult: Equatable, Sendable {
    let phase: AudioOutputIsolationPhase
    let tone: AudioOutputIsolationToneSnapshot
    let drain: AudioOutputIsolationDrainSnapshot?
}

struct AudioOutputIsolationResult: Equatable, Sendable {
    let outputDeviceName: String
    let frequency: Double
    let amplitude: Float
    let durationMilliseconds: Int
    let activeTap: AudioOutputIsolationPhaseResult
    let attribution: AudioOutputIsolationAttribution
    let processIdentity: AudioOutputIsolationProcessIdentity
    let aggregateSampleRate: Double
}

enum AudioOutputIsolationError: Error, Equatable, LocalizedError, Sendable {
    case alreadyRunning
    case invalidOutput(String)
    case lifecycle(operation: String, status: OSStatus)
    case toneDidNotComplete(AudioOutputIsolationPhase)
    case tapDrainDidNotStart
    case signalCaptureDidNotComplete(AudioOutputIsolationSignalPhase)
    case outputUnitAlreadyCreated(UInt64)
    case processObjectChanged(stage: String, expected: AudioObjectID, actual: AudioObjectID)
    case processOutputOwnershipMismatch(
        stage: String,
        processObjectID: AudioObjectID,
        expectedDeviceID: AudioObjectID,
        isRunningOutput: Bool,
        outputDeviceIDs: [AudioObjectID]
    )
    case activeOutputProcessSetMismatch(
        stage: String,
        expected: [AudioObjectID],
        actual: [AudioObjectID]
    )
    case cleanup(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "The output isolation test is already running."
        case let .invalidOutput(reason):
            return "The output isolation test cannot use this device: \(reason)."
        case let .lifecycle(operation, status):
            return "\(operation) failed: OSStatus \(status) (\(fourCC(UInt32(bitPattern: status))))"
        case let .toneDidNotComplete(phase):
            return "The bounded tone did not complete during phase '\(phase.rawValue)'."
        case .tapDrainDidNotStart:
            return "The Process Tap drain did not begin receiving callbacks."
        case let .signalCaptureDidNotComplete(phase):
            return "The Process Tap signal capture did not complete for '\(phase.rawValue)'."
        case let .outputUnitAlreadyCreated(count):
            return "The cold-start parity probe requires a fresh app process, but this process has already created \(count) output Audio Unit(s). Relaunch the app and run the probe before starting audio."
        case let .processObjectChanged(stage, expected, actual):
            return "The Core Audio process object changed at \(stage): expected \(expected), got \(actual)."
        case let .processOutputOwnershipMismatch(
            stage, processObjectID, expectedDeviceID, isRunningOutput, outputDeviceIDs
        ):
            return "The Core Audio process object \(processObjectID) did not own the active output at \(stage): running=\(isRunningOutput), expected device=\(expectedDeviceID), devices=\(outputDeviceIDs)."
        case let .activeOutputProcessSetMismatch(stage, expected, actual):
            return "The target device had unexpected active output processes at \(stage): expected=\(expected), actual=\(actual). Quit Resonance and other audio relays, relaunch EqualizerAU, and run the probe first."
        case let .cleanup(message):
            return "Output isolation cleanup failed: \(message)"
        case .cancelled:
            return "The output isolation test was stopped."
        }
    }
}

protocol AudioOutputIsolationRunning: Sendable {
    func run() async throws -> AudioOutputIsolationResult
    func cancel() async
}

protocol AudioOutputIsolationOperations: Sendable {
    func outputUnitCreationCount() -> UInt64
    func createSignal(
        deviceID: AudioObjectID,
        sampleRate: Double,
        channelCount: UInt32,
        maximumFrames: UInt32,
        monoSamples: [Float],
        output: inout OpaquePointer?
    ) -> OSStatus
    func startTone(_ output: OpaquePointer) -> OSStatus
    func stopTone(_ output: OpaquePointer) -> OSStatus
    func toneIsQuiescent(_ output: OpaquePointer) -> Bool
    func toneSnapshot(_ output: OpaquePointer) -> AudioOutputIsolationToneSnapshot
    func toneDiagnostics(
        _ output: OpaquePointer
    ) -> (status: OSStatus, diagnostics: AudioOutputIsolationToneDiagnostics)
    func destroyTone(_ output: OpaquePointer) -> OSStatus
    func createDrain(
        deviceID: AudioObjectID,
        channelCount: UInt32,
        maximumFrames: UInt32,
        signalCaptureFrameCapacity: UInt32,
        registration: inout OpaquePointer?
    ) -> OSStatus
    func startDrain(_ registration: OpaquePointer) -> OSStatus
    func stopDrain(_ registration: OpaquePointer) -> OSStatus
    func drainIsQuiescent(_ registration: OpaquePointer) -> Bool
    func drainSnapshot(_ registration: OpaquePointer) -> AudioOutputIsolationDrainSnapshot
    func beginSignalCapture(_ registration: OpaquePointer) -> OSStatus
    func endSignalCapture(_ registration: OpaquePointer) -> OSStatus
    func signalCaptureIsQuiescent(_ registration: OpaquePointer) -> Bool
    func signalCaptureWindow(
        _ registration: OpaquePointer,
        phase: AudioOutputIsolationSignalPhase,
        sampleRate: Double
    ) -> AudioOutputIsolationSignalWindow?
    func destroyDrain(_ registration: OpaquePointer) -> OSStatus
}

struct SystemAudioOutputIsolationOperations: AudioOutputIsolationOperations {
    func outputUnitCreationCount() -> UInt64 {
        EAUAudioOutputUnitGetCreationCount()
    }

    func createSignal(
        deviceID: AudioObjectID,
        sampleRate: Double,
        channelCount: UInt32,
        maximumFrames: UInt32,
        monoSamples: [Float],
        output: inout OpaquePointer?
    ) -> OSStatus {
        monoSamples.withUnsafeBufferPointer { samples in
            EAUSyntheticSignalOutputCreate(
                deviceID, sampleRate, channelCount, maximumFrames,
                samples.baseAddress, UInt32(samples.count), &output
            )
        }
    }

    func startTone(_ output: OpaquePointer) -> OSStatus {
        EAUSyntheticToneOutputStart(output)
    }

    func stopTone(_ output: OpaquePointer) -> OSStatus {
        EAUSyntheticToneOutputStop(output)
    }

    func toneIsQuiescent(_ output: OpaquePointer) -> Bool {
        EAUSyntheticToneOutputIsQuiescent(output)
    }

    func toneSnapshot(_ output: OpaquePointer) -> AudioOutputIsolationToneSnapshot {
        let value = EAUSyntheticToneOutputGetSnapshot(output)
        return AudioOutputIsolationToneSnapshot(
            callbackCount: value.callbackCount,
            renderedFrames: value.renderedFrames,
            nonZeroSampleCount: value.nonZeroSampleCount,
            lastHostTime: value.lastHostTime,
            maxObservedFrames: value.maxObservedFrames,
            faultFlags: value.faultFlags,
            silenceBlocks: value.silenceBlocks,
            nonSilenceBlocks: value.nonSilenceBlocks,
            completed: value.completed
        )
    }

    func toneDiagnostics(
        _ output: OpaquePointer
    ) -> (status: OSStatus, diagnostics: AudioOutputIsolationToneDiagnostics) {
        var value = EAUAudioOutputUnitDiagnostics()
        let status = EAUSyntheticToneOutputGetDiagnostics(output, &value)
        return (
            status,
            AudioOutputIsolationToneDiagnostics(
                componentSubType: value.componentSubType,
                currentDevice: value.currentDevice,
                deviceFormat: value.deviceFormat,
                clientFormat: value.clientFormat,
                maximumFrames: value.maximumFrames
            )
        )
    }

    func destroyTone(_ output: OpaquePointer) -> OSStatus {
        EAUSyntheticToneOutputDestroy(output)
    }

    func createDrain(
        deviceID: AudioObjectID,
        channelCount: UInt32,
        maximumFrames: UInt32,
        signalCaptureFrameCapacity: UInt32,
        registration: inout OpaquePointer?
    ) -> OSStatus {
        EAUTapDrainRegistrationCreate(
            deviceID, channelCount, maximumFrames, signalCaptureFrameCapacity, &registration
        )
    }

    func startDrain(_ registration: OpaquePointer) -> OSStatus {
        EAUTapDrainRegistrationStart(registration)
    }

    func stopDrain(_ registration: OpaquePointer) -> OSStatus {
        EAUTapDrainRegistrationStop(registration)
    }

    func drainIsQuiescent(_ registration: OpaquePointer) -> Bool {
        EAUTapDrainRegistrationIsQuiescent(registration)
    }

    func drainSnapshot(_ registration: OpaquePointer) -> AudioOutputIsolationDrainSnapshot {
        let value = EAUTapDrainRegistrationGetSnapshot(registration)
        return AudioOutputIsolationDrainSnapshot(
            callbackCount: value.callbackCount,
            capturedFrames: value.capturedFrames,
            nonZeroSampleCount: value.nonZeroSampleCount,
            lastHostTime: value.lastHostTime,
            maxObservedFrames: value.maxObservedFrames,
            faultFlags: value.faultFlags
        )
    }

    func beginSignalCapture(_ registration: OpaquePointer) -> OSStatus {
        EAUTapDrainRegistrationBeginSignalCapture(registration)
    }

    func endSignalCapture(_ registration: OpaquePointer) -> OSStatus {
        EAUTapDrainRegistrationEndSignalCapture(registration)
    }

    func signalCaptureIsQuiescent(_ registration: OpaquePointer) -> Bool {
        EAUTapDrainRegistrationSignalCaptureIsQuiescent(registration)
    }

    func signalCaptureWindow(
        _ registration: OpaquePointer,
        phase: AudioOutputIsolationSignalPhase,
        sampleRate: Double
    ) -> AudioOutputIsolationSignalWindow? {
        let metadata = EAUTapDrainRegistrationGetSignalCaptureMetadata(registration)
        let sampleCount64 = UInt64(metadata.frameCount) * UInt64(metadata.channelCount)
        guard metadata.frameCount > 0, metadata.channelCount > 0,
              sampleCount64 <= UInt64(UInt32.max), sampleCount64 <= UInt64(Int.max)
        else { return nil }
        var samples = [Float](repeating: 0, count: Int(sampleCount64))
        let copied = samples.withUnsafeMutableBufferPointer { buffer in
            EAUTapDrainRegistrationCopySignalCapture(
                registration, buffer.baseAddress, UInt32(buffer.count)
            )
        }
        guard copied == UInt32(samples.count) else { return nil }
        return AudioOutputIsolationSignalWindow(
            phase: phase,
            sequence: metadata.sequence,
            firstHostTime: metadata.firstHostTime,
            droppedFrames: metadata.droppedFrames,
            frameCount: metadata.frameCount,
            channelCount: metadata.channelCount,
            sampleRate: sampleRate,
            samples: samples
        )
    }

    func destroyDrain(_ registration: OpaquePointer) -> OSStatus {
        EAUTapDrainRegistrationDestroy(registration)
    }
}

struct AudioOutputIsolationChallengeGenerator: Sendable {
    func make(
        seed: UInt64,
        sampleRate: Double,
        carrierFrequency: Double,
        amplitude: Float,
        durationFrames: UInt32,
        chipFrames: UInt32,
        fadeFrames: UInt32
    ) throws -> AudioOutputIsolationChallenge {
        guard sampleRate.isFinite, sampleRate > 0,
              carrierFrequency.isFinite, carrierFrequency > 0,
              carrierFrequency < sampleRate / 2,
              amplitude.isFinite, amplitude > 0, amplitude <= 0.05,
              durationFrames > 0, chipFrames > 0,
              fadeFrames <= durationFrames / 2 else {
            throw AudioOutputIsolationError.invalidOutput("invalid challenge waveform settings")
        }

        var state = seed
        var polarity = 1.0
        var samples = [Float](repeating: 0, count: Int(durationFrames))
        for frame in 0..<durationFrames {
            if frame % chipFrames == 0 {
                state &+= 0x9E37_79B9_7F4A_7C15
                var value = state
                value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
                value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
                value ^= value >> 31
                polarity = value & 1 == 0 ? -1 : 1
            }
            var envelope = 1.0
            if fadeFrames > 0, frame < fadeFrames {
                envelope *= 0.5 - 0.5 * cos(Double.pi * Double(frame) / Double(fadeFrames))
            }
            let remaining = durationFrames - 1 - frame
            if fadeFrames > 0, remaining < fadeFrames {
                envelope *= 0.5 - 0.5 * cos(Double.pi * Double(remaining) / Double(fadeFrames))
            }
            samples[Int(frame)] = Float(
                Double(amplitude) * envelope * polarity
                    * sin(2 * Double.pi * carrierFrequency * Double(frame) / sampleRate)
            )
        }
        return AudioOutputIsolationChallenge(
            seed: seed,
            sampleRate: sampleRate,
            carrierFrequencyHz: carrierFrequency,
            amplitude: amplitude,
            chipFrames: chipFrames,
            samples: samples
        )
    }
}

actor AudioOutputIsolationTestController: AudioOutputIsolationRunning {
    static let frequency = 660.0
    static let amplitude: Float = 0.02
    static let durationMilliseconds = 1_000
    static let activeCaptureTailMilliseconds = 250
    static let signalCaptureCapacityMilliseconds = 1_500
    static let challengeChipMilliseconds = 10
    static let fadeMilliseconds = 30

    private struct Resources {
        var tone: OpaquePointer?
        var toneStarted = false
        var tap: ProcessTapResource?
        var aggregate: AggregateDeviceResource?
        var drain: OpaquePointer?
        var drainStarted = false
        var signalCaptureStarted = false

        var isEmpty: Bool {
            tone == nil && tap == nil && aggregate == nil && drain == nil
        }
    }

    private let outputDiscovery: any DefaultOutputDeviceDiscovering
    private let tapController: any ProcessTapControlling
    private let aggregateController: any AggregateDeviceControlling
    private let operations: any AudioOutputIsolationOperations
    private let debugLogger: any AudioDebugLogging
    private let evidenceRecorder: any AudioOutputIsolationEvidenceRecording
    private let signalAnalyzer = AudioOutputIsolationSignalAnalyzer()
    private let challengeGenerator = AudioOutputIsolationChallengeGenerator()
    private let phaseDelay: @Sendable (Duration) async throws -> Void
    private let challengeSeedProvider: @Sendable () -> UInt64
    private var resources = Resources()
    private var running = false
    private var cancellationRequested = false
    private var generationValue: UInt64 = 10_000

    init(
        outputDiscovery: any DefaultOutputDeviceDiscovering = DefaultOutputDeviceDiscovery(),
        tapController: any ProcessTapControlling = ProcessTapController(),
        aggregateController: any AggregateDeviceControlling = AggregateDeviceController(),
        operations: any AudioOutputIsolationOperations = SystemAudioOutputIsolationOperations(),
        debugLogger: any AudioDebugLogging = AudioDebugLogger.shared,
        evidenceRecorder: any AudioOutputIsolationEvidenceRecording =
            AudioOutputIsolationEvidenceRecorder.shared,
        phaseDelay: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        challengeSeedProvider: @escaping @Sendable () -> UInt64 = {
            UInt64.random(in: 1...UInt64.max)
        }
    ) {
        self.outputDiscovery = outputDiscovery
        self.tapController = tapController
        self.aggregateController = aggregateController
        self.operations = operations
        self.debugLogger = debugLogger
        self.evidenceRecorder = evidenceRecorder
        self.phaseDelay = phaseDelay
        self.challengeSeedProvider = challengeSeedProvider
    }

    func run() async throws -> AudioOutputIsolationResult {
        guard !running else { throw AudioOutputIsolationError.alreadyRunning }
        running = true
        cancellationRequested = false
        if !resources.isEmpty {
            let retryErrors = await cleanup()
            guard retryErrors.isEmpty, resources.isEmpty else {
                running = false
                throw AudioOutputIsolationError.cleanup(
                    retryErrors.isEmpty
                        ? "previous isolation resources remain owned"
                        : retryErrors.joined(separator: " ")
                )
            }
        }
        resources = Resources()
        generationValue &+= 1
        let generation = AudioGeneration(rawValue: generationValue)

        do {
            let priorOutputUnitCount = operations.outputUnitCreationCount()
            guard priorOutputUnitCount == 0 else {
                throw AudioOutputIsolationError.outputUnitAlreadyCreated(priorOutputUnitCount)
            }
            let output = try await outputDiscovery.snapshot(generation: generation)
            let preflightProcessObjectID = try await tapController.currentProcessObjectID()
            let activeOutputProcessesBeforeTap = try await validateActiveOutputProcesses(
                deviceID: output.objectID,
                expected: [],
                stage: "before Process Tap creation"
            )
            let maximumFrames = try maximumFrameCapacity(output)
            let channelCount = output.outputLayout.totalChannelCount
            guard output.nominalSampleRate <= Double(UInt32.max), channelCount > 0 else {
                throw AudioOutputIsolationError.invalidOutput("invalid sample rate or channel count")
            }
            let durationFrames = UInt32(
                (output.nominalSampleRate * Double(Self.durationMilliseconds) / 1_000).rounded()
            )
            let fadeFrames = UInt32(
                (output.nominalSampleRate * Double(Self.fadeMilliseconds) / 1_000).rounded()
            )
            let chipFrames = UInt32(max(
                1,
                (output.nominalSampleRate * Double(Self.challengeChipMilliseconds) / 1_000)
                    .rounded()
            ))
            let challenge = try challengeGenerator.make(
                seed: challengeSeedProvider(),
                sampleRate: output.nominalSampleRate,
                carrierFrequency: Self.frequency,
                amplitude: Self.amplitude,
                durationFrames: durationFrames,
                chipFrames: chipFrames,
                fadeFrames: fadeFrames
            )
            await debugLogger.log("isolation.start", generation: generation, fields: [
                "deviceID": "\(output.objectID)", "deviceUID": output.uid,
                "sampleRate": "\(output.nominalSampleRate)", "channels": "\(channelCount)",
                "frequency": "\(Self.frequency)", "amplitude": "\(Self.amplitude)",
                "durationFrames": "\(durationFrames)",
                "challengeSeed": "\(challenge.seed)", "chipFrames": "\(chipFrames)",
                "lifecycle": "cold-muted-exclusive-raw-capture-then-single-output"
            ])

            let createdTap = try await tapController.create(
                configuration: ProcessTapConfiguration(
                    generation: generation,
                    name: "EqualizerAU Resonance Parity Tap",
                    muteBehavior: .muted,
                    outputDeviceUID: output.uid,
                    outputStreamIndex: 0
                )
            )
            resources.tap = createdTap
            guard createdTap.selfProcessObjectID == preflightProcessObjectID else {
                throw AudioOutputIsolationError.processObjectChanged(
                    stage: "during Process Tap creation",
                    expected: preflightProcessObjectID,
                    actual: createdTap.selfProcessObjectID
                )
            }
            let createdAggregate = try await aggregateController.create(
                configuration: AggregateDeviceConfiguration(
                    generation: generation,
                    uidPrefix: "com.ruimingchen.EqualizerAU.isolation.aggregate",
                    name: "EqualizerAU Resonance Parity Capture"
                ),
                output: output,
                tap: createdTap
            )
            resources.aggregate = createdAggregate

            let signalCaptureFramesDouble = (
                createdAggregate.nominalSampleRate
                    * Double(Self.signalCaptureCapacityMilliseconds) / 1_000
            ).rounded(.up)
            guard signalCaptureFramesDouble > 0,
                  signalCaptureFramesDouble <= Double(UInt32.max) else {
                throw AudioOutputIsolationError.invalidOutput("invalid signal-capture capacity")
            }
            let signalCaptureFrameCapacity = UInt32(signalCaptureFramesDouble)

            var drain: OpaquePointer?
            let drainCreateStatus = operations.createDrain(
                deviceID: createdAggregate.objectID,
                channelCount: createdAggregate.inputLayout.totalChannelCount,
                maximumFrames: createdAggregate.maximumFrames,
                signalCaptureFrameCapacity: signalCaptureFrameCapacity,
                registration: &drain
            )
            guard drainCreateStatus == noErr, let drain else {
                throw AudioOutputIsolationError.lifecycle(
                    operation: "Create Process Tap drain",
                    status: drainCreateStatus == noErr ? kAudioHardwareBadObjectError : drainCreateStatus
                )
            }
            resources.drain = drain
            try statusCheck(
                operations.startDrain(drain), operation: "Start Process Tap drain"
            )
            resources.drainStarted = true
            try await beginSignalCapture(drain, phase: .challengeCapture)
            let tone = try createSignal(
                output: output,
                channelCount: channelCount,
                maximumFrames: maximumFrames,
                challenge: challenge
            )
            let outputUnitCount = operations.outputUnitCreationCount()
            guard outputUnitCount == 1 else {
                throw AudioOutputIsolationError.invalidOutput(
                    "expected exactly one output Audio Unit after challenge initialization, got \(outputUnitCount)"
                )
            }
            try validateToneDiagnostics(
                operations.toneDiagnostics(tone),
                output: output,
                channelCount: channelCount,
                maximumFrames: maximumFrames
            )
            let afterInitialization = try await validateProcessObjectID(
                expected: createdTap.selfProcessObjectID,
                stage: "after DefaultOutput initialization"
            )
            let (
                active,
                afterFirstRender,
                outputOwnership,
                activeOutputProcessesAfterFirstRender,
                activeOutputProcessesBeforeStop
            ) = try await runTonePhase(
                .mutedSelfExcludingTap,
                tone: tone,
                expectedProcessObjectID: createdTap.selfProcessObjectID,
                expectedOutputDeviceID: output.objectID,
                generation: generation
            )
            try await destroyOwnedTone(operation: "Destroy challenge DefaultOutput")
            try await phaseDelay(.milliseconds(Self.activeCaptureTailMilliseconds))
            try checkCancellation()
            let captureWindow = try await finishSignalCapture(
                drain,
                phase: .challengeCapture,
                sampleRate: createdAggregate.nominalSampleRate
            )
            let drainResult = operations.drainSnapshot(drain)
            guard drainResult.callbackCount > 0 else {
                throw AudioOutputIsolationError.tapDrainDidNotStart
            }
            let attribution = try signalAnalyzer.compare(
                capture: captureWindow,
                challenge: challenge,
                drainFaultFlags: drainResult.faultFlags
            )
            await evidenceRecorder.record(
                challenge: challenge,
                capture: captureWindow,
                attribution: attribution,
                generation: generation,
                logger: debugLogger
            )
            let activeWithDrain = AudioOutputIsolationPhaseResult(
                phase: active.phase, tone: active.tone, drain: drainResult
            )
            let processIdentity = AudioOutputIsolationProcessIdentity(
                tapCreation: createdTap.selfProcessObjectID,
                afterOutputInitialization: afterInitialization,
                afterFirstRender: afterFirstRender,
                outputOwnershipAfterFirstRender: outputOwnership,
                activeOutputProcessesBeforeTap: activeOutputProcessesBeforeTap,
                activeOutputProcessesAfterFirstRender: activeOutputProcessesAfterFirstRender,
                activeOutputProcessesBeforeStop: activeOutputProcessesBeforeStop
            )

            let cleanupErrors = await cleanup()
            guard cleanupErrors.isEmpty else {
                throw AudioOutputIsolationError.cleanup(cleanupErrors.joined(separator: " "))
            }
            running = false
            await debugLogger.log("isolation.completed", generation: generation, fields: [
                "activeTapCallbacks": "\(active.tone.callbackCount)",
                "activeTapNonZero": "\(active.tone.nonZeroSampleCount)",
                "drainCallbacks": "\(drainResult.callbackCount)",
                "drainFrames": "\(drainResult.capturedFrames)",
                "drainNonZero": "\(drainResult.nonZeroSampleCount)",
                "drainFaultFlags": "0x\(String(drainResult.faultFlags, radix: 16))",
                "challengeCorrelation": "\(attribution.capture.challengeCorrelation)",
                "challengeLagFrames": "\(attribution.capture.challengeLagFrames)",
                "estimatedGainDB": "\(attribution.capture.estimatedGainDB)",
                "processObjectID": "\(createdTap.selfProcessObjectID)",
                "processIsRunningOutput": "\(outputOwnership.isRunningOutput)",
                "processOutputDeviceIDs": outputOwnership.outputDeviceIDs.map(String.init).joined(separator: ","),
                "activeOutputProcessesBeforeTap": activeOutputProcessesBeforeTap.map(String.init).joined(separator: ","),
                "activeOutputProcessesAfterFirstRender": activeOutputProcessesAfterFirstRender.map(String.init).joined(separator: ","),
                "activeOutputProcessesBeforeStop": activeOutputProcessesBeforeStop.map(String.init).joined(separator: ","),
                "recaptureVerdict": attribution.verdict.rawValue,
                "recaptureReason": attribution.reason
            ])
            return AudioOutputIsolationResult(
                outputDeviceName: output.displayDescription,
                frequency: Self.frequency,
                amplitude: Self.amplitude,
                durationMilliseconds: Self.durationMilliseconds,
                activeTap: activeWithDrain,
                attribution: attribution,
                processIdentity: processIdentity,
                aggregateSampleRate: createdAggregate.nominalSampleRate
            )
        } catch {
            let cleanupErrors = await cleanup()
            running = false
            await debugLogger.log("isolation.failed", generation: generation, fields: [
                "error": error.localizedDescription,
                "cleanupError": cleanupErrors.joined(separator: " ")
            ])
            if !cleanupErrors.isEmpty {
                throw AudioOutputIsolationError.cleanup(
                    "\(error.localizedDescription) \(cleanupErrors.joined(separator: " "))"
                )
            }
            if error is CancellationError || cancellationRequested {
                throw AudioOutputIsolationError.cancelled
            }
            throw error
        }
    }

    func cancel() {
        cancellationRequested = true
    }

    private func createSignal(
        output: AudioDeviceSnapshot,
        channelCount: UInt32,
        maximumFrames: UInt32,
        challenge: AudioOutputIsolationChallenge
    ) throws -> OpaquePointer {
        var tone: OpaquePointer?
        let status = operations.createSignal(
            deviceID: output.objectID,
            sampleRate: output.nominalSampleRate,
            channelCount: channelCount,
            maximumFrames: maximumFrames,
            monoSamples: challenge.samples,
            output: &tone
        )
        guard status == noErr, let tone else {
            throw AudioOutputIsolationError.lifecycle(
                operation: "Create nonce-coded DefaultOutput challenge",
                status: status == noErr ? kAudioHardwareBadObjectError : status
            )
        }
        resources.tone = tone
        return tone
    }

    private func destroyOwnedTone(operation: String) async throws {
        guard let tone = resources.tone else { return }
        guard !resources.toneStarted else {
            throw AudioOutputIsolationError.invalidOutput("cannot destroy a started tone output")
        }
        try await waitForToneQuiescence(tone)
        let status = operations.destroyTone(tone)
        guard status == noErr else {
            throw AudioOutputIsolationError.lifecycle(operation: operation, status: status)
        }
        resources.tone = nil
    }

    private func beginSignalCapture(
        _ drain: OpaquePointer,
        phase: AudioOutputIsolationSignalPhase
    ) async throws {
        try await waitForSignalCaptureQuiescence(drain, phase: phase)
        let deadline = ContinuousClock.now + .milliseconds(100)
        while true {
            let status = operations.beginSignalCapture(drain)
            if status == noErr {
                resources.signalCaptureStarted = true
                return
            }
            guard status == kAudioHardwareIllegalOperationError,
                  ContinuousClock.now < deadline else {
                throw AudioOutputIsolationError.lifecycle(
                    operation: "Begin \(phase.rawValue) Process Tap signal capture",
                    status: status
                )
            }
            try checkCancellation()
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func finishSignalCapture(
        _ drain: OpaquePointer,
        phase: AudioOutputIsolationSignalPhase,
        sampleRate: Double
    ) async throws -> AudioOutputIsolationSignalWindow {
        guard resources.signalCaptureStarted else {
            throw AudioOutputIsolationError.signalCaptureDidNotComplete(phase)
        }
        let status = operations.endSignalCapture(drain)
        if status == noErr { resources.signalCaptureStarted = false }
        try statusCheck(status, operation: "End \(phase.rawValue) Process Tap signal capture")
        try await waitForSignalCaptureQuiescence(drain, phase: phase)
        guard let window = operations.signalCaptureWindow(
            drain, phase: phase, sampleRate: sampleRate
        ) else {
            throw AudioOutputIsolationError.signalCaptureDidNotComplete(phase)
        }
        return window
    }

    private func runTonePhase(
        _ phase: AudioOutputIsolationPhase,
        tone: OpaquePointer,
        expectedProcessObjectID: AudioObjectID,
        expectedOutputDeviceID: AudioObjectID,
        generation: AudioGeneration
    ) async throws -> (
        AudioOutputIsolationPhaseResult,
        AudioObjectID,
        CoreAudioProcessOutputState,
        [AudioObjectID],
        [AudioObjectID]
    ) {
        try checkCancellation()
        await debugLogger.log("isolation.phase.start", generation: generation, fields: [
            "phase": phase.rawValue
        ])
        try statusCheck(
            operations.startTone(tone), operation: "Start bounded tone for \(phase.rawValue)"
        )
        resources.toneStarted = true
        let deadline = ContinuousClock.now + .milliseconds(Self.durationMilliseconds + 1_000)
        var snapshot = operations.toneSnapshot(tone)
        var afterFirstRender: AudioObjectID?
        var outputOwnership: CoreAudioProcessOutputState?
        var activeOutputProcessesAfterFirstRender: [AudioObjectID]?
        while !snapshot.completed, ContinuousClock.now < deadline {
            if snapshot.callbackCount > 0, afterFirstRender == nil {
                afterFirstRender = try await validateProcessObjectID(
                    expected: expectedProcessObjectID,
                    stage: "after first DefaultOutput render"
                )
                outputOwnership = try await validateProcessOutputOwnership(
                    processObjectID: expectedProcessObjectID,
                    expectedDeviceID: expectedOutputDeviceID,
                    stage: "after first DefaultOutput render"
                )
                activeOutputProcessesAfterFirstRender = try await validateActiveOutputProcesses(
                    deviceID: expectedOutputDeviceID,
                    expected: [expectedProcessObjectID],
                    stage: "after first DefaultOutput render"
                )
            }
            try checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
            snapshot = operations.toneSnapshot(tone)
        }
        if snapshot.callbackCount > 0, afterFirstRender == nil {
            afterFirstRender = try await validateProcessObjectID(
                expected: expectedProcessObjectID,
                stage: "after first DefaultOutput render"
            )
            outputOwnership = try await validateProcessOutputOwnership(
                processObjectID: expectedProcessObjectID,
                expectedDeviceID: expectedOutputDeviceID,
                stage: "after first DefaultOutput render"
            )
            activeOutputProcessesAfterFirstRender = try await validateActiveOutputProcesses(
                deviceID: expectedOutputDeviceID,
                expected: [expectedProcessObjectID],
                stage: "after first DefaultOutput render"
            )
        }
        let activeOutputProcessesBeforeStop = try await validateActiveOutputProcesses(
            deviceID: expectedOutputDeviceID,
            expected: [expectedProcessObjectID],
            stage: "before stopping challenge output"
        )
        let stopStatus = operations.stopTone(tone)
        if stopStatus == noErr { resources.toneStarted = false }
        try statusCheck(stopStatus, operation: "Stop bounded tone for \(phase.rawValue)")
        try await waitForToneQuiescence(tone)
        guard snapshot.completed else {
            throw AudioOutputIsolationError.toneDidNotComplete(phase)
        }
        guard snapshot.faultFlags == 0 else {
            throw AudioOutputIsolationError.invalidOutput(
                "tone callback fault flags 0x\(String(snapshot.faultFlags, radix: 16))"
            )
        }
        guard let afterFirstRender else {
            throw AudioOutputIsolationError.invalidOutput(
                "challenge output completed without a render callback identity check"
            )
        }
        guard let outputOwnership else {
            throw AudioOutputIsolationError.invalidOutput(
                "challenge output completed without a Core Audio output-ownership check"
            )
        }
        guard let activeOutputProcessesAfterFirstRender else {
            throw AudioOutputIsolationError.invalidOutput(
                "challenge output completed without an active-output process-set check"
            )
        }
        await debugLogger.log("isolation.phase.complete", generation: generation, fields: [
            "phase": phase.rawValue,
            "callbacks": "\(snapshot.callbackCount)",
            "renderedFrames": "\(snapshot.renderedFrames)",
            "nonZeroSamples": "\(snapshot.nonZeroSampleCount)",
            "silenceBlocks": "\(snapshot.silenceBlocks)",
            "nonSilenceBlocks": "\(snapshot.nonSilenceBlocks)",
            "faultFlags": "0x\(String(snapshot.faultFlags, radix: 16))"
        ])
        return (
            AudioOutputIsolationPhaseResult(phase: phase, tone: snapshot, drain: nil),
            afterFirstRender,
            outputOwnership,
            activeOutputProcessesAfterFirstRender,
            activeOutputProcessesBeforeStop
        )
    }

    private func validateToneDiagnostics(
        _ result: (status: OSStatus, diagnostics: AudioOutputIsolationToneDiagnostics),
        output: AudioDeviceSnapshot,
        channelCount: UInt32,
        maximumFrames: UInt32
    ) throws {
        try statusCheck(result.status, operation: "Read challenge DefaultOutput diagnostics")
        let diagnostics = result.diagnostics
        let client = diagnostics.clientFormat
        let expectedBytesPerFrame = channelCount * UInt32(MemoryLayout<Float>.size)
        guard diagnostics.componentSubType == kAudioUnitSubType_DefaultOutput,
              diagnostics.currentDevice == output.objectID,
              diagnostics.maximumFrames == maximumFrames,
              client.mFormatID == kAudioFormatLinearPCM,
              client.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              client.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              client.mSampleRate.isFinite,
              abs(client.mSampleRate - output.nominalSampleRate) < 0.5,
              client.mChannelsPerFrame == channelCount,
              client.mFramesPerPacket == 1,
              client.mBitsPerChannel == 32,
              client.mBytesPerFrame == expectedBytesPerFrame,
              client.mBytesPerPacket == expectedBytesPerFrame else {
            throw AudioOutputIsolationError.invalidOutput(
                "challenge output diagnostics do not match Resonance's DefaultOutput contract"
            )
        }
    }

    private func validateProcessObjectID(
        expected: AudioObjectID,
        stage: String
    ) async throws -> AudioObjectID {
        let actual = try await tapController.currentProcessObjectID()
        guard actual == expected else {
            throw AudioOutputIsolationError.processObjectChanged(
                stage: stage,
                expected: expected,
                actual: actual
            )
        }
        return actual
    }

    private func validateProcessOutputOwnership(
        processObjectID: AudioObjectID,
        expectedDeviceID: AudioObjectID,
        stage: String
    ) async throws -> CoreAudioProcessOutputState {
        let state = try await tapController.outputState(processObjectID: processObjectID)
        guard state.processObjectID == processObjectID,
              state.isRunningOutput,
              state.outputDeviceIDs.contains(expectedDeviceID) else {
            throw AudioOutputIsolationError.processOutputOwnershipMismatch(
                stage: stage,
                processObjectID: processObjectID,
                expectedDeviceID: expectedDeviceID,
                isRunningOutput: state.isRunningOutput,
                outputDeviceIDs: state.outputDeviceIDs
            )
        }
        return state
    }

    private func validateActiveOutputProcesses(
        deviceID: AudioObjectID,
        expected: [AudioObjectID],
        stage: String
    ) async throws -> [AudioObjectID] {
        let actual = try await tapController.activeOutputProcessObjectIDs(deviceID: deviceID)
        let sortedExpected = expected.sorted()
        guard actual == sortedExpected else {
            throw AudioOutputIsolationError.activeOutputProcessSetMismatch(
                stage: stage,
                expected: sortedExpected,
                actual: actual
            )
        }
        return actual
    }

    private func waitForToneQuiescence(_ tone: OpaquePointer) async throws {
        for _ in 0..<100 where !operations.toneIsQuiescent(tone) {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard operations.toneIsQuiescent(tone) else {
            throw AudioOutputIsolationError.invalidOutput("tone callback did not quiesce")
        }
    }

    private func waitForSignalCaptureQuiescence(
        _ drain: OpaquePointer,
        phase: AudioOutputIsolationSignalPhase
    ) async throws {
        for _ in 0..<100 where !operations.signalCaptureIsQuiescent(drain) {
            try checkCancellation()
            try await Task.sleep(for: .milliseconds(1))
        }
        guard operations.signalCaptureIsQuiescent(drain) else {
            throw AudioOutputIsolationError.signalCaptureDidNotComplete(phase)
        }
    }

    private func cleanup() async -> [String] {
        var errors: [String] = []
        if resources.toneStarted, let tone = resources.tone {
            let status = operations.stopTone(tone)
            if status == noErr {
                resources.toneStarted = false
            } else {
                errors.append(statusDescription("Stop bounded tone", status))
            }
        }
        var captureEndFailure: OSStatus?
        if resources.signalCaptureStarted, let drain = resources.drain {
            let status = operations.endSignalCapture(drain)
            if status == noErr {
                resources.signalCaptureStarted = false
            } else {
                captureEndFailure = status
            }
        }
        if !resources.toneStarted, let tone = resources.tone {
            for _ in 0..<100 where !operations.toneIsQuiescent(tone) {
                try? await Task.sleep(for: .milliseconds(1))
            }
            if operations.toneIsQuiescent(tone) {
                let status = operations.destroyTone(tone)
                if status == noErr {
                    resources.tone = nil
                } else {
                    errors.append(statusDescription("Destroy bounded tone", status))
                }
            } else {
                errors.append("Bounded tone callback did not quiesce")
            }
        }
        guard resources.tone == nil else {
            if let captureEndFailure {
                errors.append(statusDescription("End Process Tap signal capture", captureEndFailure))
            }
            return errors
        }
        if resources.drainStarted, let drain = resources.drain {
            let status = operations.stopDrain(drain)
            if status == noErr {
                resources.drainStarted = false
            } else {
                errors.append(statusDescription("Stop Process Tap drain", status))
            }
        }
        if resources.signalCaptureStarted, let drain = resources.drain {
            let retryStatus = operations.endSignalCapture(drain)
            if retryStatus == noErr {
                resources.signalCaptureStarted = false
                captureEndFailure = nil
            } else {
                captureEndFailure = retryStatus
            }
        }
        if let captureEndFailure {
            errors.append(statusDescription("End Process Tap signal capture", captureEndFailure))
        }
        if !resources.drainStarted, let drain = resources.drain {
            for _ in 0..<100 where !operations.drainIsQuiescent(drain) {
                try? await Task.sleep(for: .milliseconds(1))
            }
            for _ in 0..<100 where !operations.signalCaptureIsQuiescent(drain) {
                try? await Task.sleep(for: .milliseconds(1))
            }
            if operations.drainIsQuiescent(drain),
               operations.signalCaptureIsQuiescent(drain),
               !resources.signalCaptureStarted {
                let status = operations.destroyDrain(drain)
                if status == noErr {
                    resources.drain = nil
                } else {
                    errors.append(statusDescription("Destroy Process Tap drain", status))
                }
            } else {
                errors.append("Process Tap drain or signal-capture callback did not quiesce")
            }
        }
        if resources.drain == nil, let aggregate = resources.aggregate {
            do {
                try await aggregateController.destroy(aggregate)
                resources.aggregate = nil
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        if resources.drain == nil, resources.aggregate == nil, let tap = resources.tap {
            do {
                try await tapController.destroy(tap)
                resources.tap = nil
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        return errors
    }

    private func maximumFrameCapacity(_ output: AudioDeviceSnapshot) throws -> UInt32 {
        let upper = output.bufferFrameSizeRange.upperBound.rounded(.up)
        guard upper.isFinite, upper > 0, upper <= Double(UInt32.max) else {
            throw AudioOutputIsolationError.invalidOutput("invalid frame-size range")
        }
        return max(output.bufferFrameSize, UInt32(upper))
    }

    private func checkCancellation() throws {
        if cancellationRequested || Task.isCancelled {
            throw CancellationError()
        }
    }

    private func statusCheck(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw AudioOutputIsolationError.lifecycle(operation: operation, status: status)
        }
    }

    private func statusDescription(_ operation: String, _ status: OSStatus) -> String {
        "\(operation): OSStatus \(status) (\(fourCC(UInt32(bitPattern: status))))"
    }
}
