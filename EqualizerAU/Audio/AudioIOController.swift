import CoreAudio
import Foundation

struct AudioIOBridgeSnapshot: Equatable, Sendable {
    let callbackCount: UInt64
    let frameCount: UInt64
    let nonZeroSampleCount: UInt64
    let lastHostTime: UInt64
    let maxObservedFrames: UInt32
    let faultFlags: UInt32
    let inFlightCallbacks: UInt32
    let captureCallbackCount: UInt64
    let outputCallbackCount: UInt64
    let capturedFrames: UInt64
    let renderedFrames: UInt64
    let renderedNonZeroSampleCount: UInt64
    let underrunBlocks: UInt64
    let overflowFrames: UInt64
    let droppedFrames: UInt64
    let primingBlocks: UInt64
    let backlogCorrections: UInt64
    let renderActionSilenceInputBlocks: UInt64
    let renderActionSilenceClearedBlocks: UInt64
    let outputSilenceBlocks: UInt64
    let outputNonSilenceBlocks: UInt64
    let ringFillFrames: UInt32
    let fadeComplete: Bool

    init(
        callbackCount: UInt64,
        frameCount: UInt64,
        nonZeroSampleCount: UInt64,
        lastHostTime: UInt64,
        maxObservedFrames: UInt32,
        faultFlags: UInt32,
        inFlightCallbacks: UInt32,
        captureCallbackCount: UInt64 = 0,
        outputCallbackCount: UInt64 = 0,
        capturedFrames: UInt64 = 0,
        renderedFrames: UInt64 = 0,
        renderedNonZeroSampleCount: UInt64 = 0,
        underrunBlocks: UInt64 = 0,
        overflowFrames: UInt64 = 0,
        droppedFrames: UInt64 = 0,
        primingBlocks: UInt64 = 0,
        backlogCorrections: UInt64 = 0,
        renderActionSilenceInputBlocks: UInt64 = 0,
        renderActionSilenceClearedBlocks: UInt64 = 0,
        outputSilenceBlocks: UInt64 = 0,
        outputNonSilenceBlocks: UInt64 = 0,
        ringFillFrames: UInt32 = 0,
        fadeComplete: Bool = true
    ) {
        self.callbackCount = callbackCount
        self.frameCount = frameCount
        self.nonZeroSampleCount = nonZeroSampleCount
        self.lastHostTime = lastHostTime
        self.maxObservedFrames = maxObservedFrames
        self.faultFlags = faultFlags
        self.inFlightCallbacks = inFlightCallbacks
        self.captureCallbackCount = captureCallbackCount
        self.outputCallbackCount = outputCallbackCount
        self.capturedFrames = capturedFrames
        self.renderedFrames = renderedFrames
        self.renderedNonZeroSampleCount = renderedNonZeroSampleCount
        self.underrunBlocks = underrunBlocks
        self.overflowFrames = overflowFrames
        self.droppedFrames = droppedFrames
        self.primingBlocks = primingBlocks
        self.backlogCorrections = backlogCorrections
        self.renderActionSilenceInputBlocks = renderActionSilenceInputBlocks
        self.renderActionSilenceClearedBlocks = renderActionSilenceClearedBlocks
        self.outputSilenceBlocks = outputSilenceBlocks
        self.outputNonSilenceBlocks = outputNonSilenceBlocks
        self.ringFillFrames = ringFillFrames
        self.fadeComplete = fadeComplete
    }
}

struct AudioOutputUnitDiagnostics: Sendable {
    let componentSubType: OSType
    let currentDevice: AudioObjectID
    let deviceFormat: AudioStreamBasicDescription
    let clientFormat: AudioStreamBasicDescription
    let maximumFrames: UInt32
    let isRunning: Bool
    let volume: Float?
    let isRunningStatus: OSStatus
    let volumeStatus: OSStatus
}

enum AudioSignalStage: String, CaseIterable, Codable, Hashable, Sendable {
    case capture
    case postDSP
    case appleSubmit

    var bridgeValue: EAUAudioSignalProbeStage {
        switch self {
        case .capture: EAUAudioSignalProbeCapture
        case .postDSP: EAUAudioSignalProbePostDSP
        case .appleSubmit: EAUAudioSignalProbeAppleSubmit
        }
    }
}

struct AudioSignalProbeWindow: Equatable, Sendable {
    let stage: AudioSignalStage
    let sequence: UInt64
    let hostTime: UInt64
    let droppedFrames: UInt64
    let frameCount: UInt32
    let channelCount: UInt32
    let sampleRate: Double
    let samples: [Float]
}

struct AudioIOResource: @unchecked Sendable {
    let descriptor: AudioResourceDescriptor
    let captureRegistration: OpaquePointer
    let outputRegistration: OpaquePointer?
    let bridge: OpaquePointer
    let sampleRate: Double
    private(set) var isCaptureStarted: Bool
    private(set) var isOutputStarted: Bool

    var objectID: AudioObjectID { descriptor.objectID }
    var ownershipToken: UUID { descriptor.ownershipToken }
}

enum AudioIOError: Error, Equatable, LocalizedError, Sendable {
    case invalidFormat(String)
    case incompatibleBufferLayouts(input: [UInt32], output: [UInt32])
    case bridgeCreationFailed
    case lifecycle(operation: String, status: OSStatus)
    case callbacksDidNotQuiesce
    case staleResource
    case operationInProgress(String)

    var errorDescription: String? {
        switch self {
        case let .invalidFormat(reason):
            return "Unsupported M0 buffered audio format: \(reason)."
        case let .incompatibleBufferLayouts(input, output):
            return "Buffered transport requires equal total channel counts; got \(input) and \(output)."
        case .bridgeCreationFailed:
            return "Unable to allocate the fixed-capacity buffered audio bridge."
        case let .lifecycle(operation, status):
            return "\(operation) failed: OSStatus \(status) (\(fourCC(UInt32(bitPattern: status))))"
        case .callbacksDidNotQuiesce:
            return "Audio callbacks did not exit after both devices stopped."
        case .staleResource:
            return "The audio IO resource is stale or belongs to a different controller."
        case let .operationInProgress(operation):
            return "Audio IO resource is busy with \(operation)."
        }
    }
}

protocol AudioDeviceIOOperations: Sendable {
    func createCaptureIOProc(
        deviceID: AudioObjectID,
        bridge: OpaquePointer,
        registration: inout OpaquePointer?
    ) -> OSStatus
    func createOutputUnit(
        deviceID: AudioObjectID,
        bridge: OpaquePointer,
        sampleRate: Double,
        channelCount: UInt32,
        maximumFrames: UInt32,
        outputUnit: inout OpaquePointer?
    ) -> OSStatus
    func startCapture(registration: OpaquePointer) -> OSStatus
    func stopCapture(registration: OpaquePointer) -> OSStatus
    func destroyCapture(registration: OpaquePointer) -> OSStatus
    func startOutput(outputUnit: OpaquePointer) -> OSStatus
    func stopOutput(outputUnit: OpaquePointer) -> OSStatus
    func destroyOutput(outputUnit: OpaquePointer) -> OSStatus
    func outputDiagnostics(outputUnit: OpaquePointer) -> Result<AudioOutputUnitDiagnostics, AudioIOError>
}

extension AudioDeviceIOOperations {
    func outputDiagnostics(outputUnit: OpaquePointer) -> Result<AudioOutputUnitDiagnostics, AudioIOError> {
        .failure(.lifecycle(operation: "Read physical output AUHAL diagnostics", status: kAudioHardwareUnsupportedOperationError))
    }
}

protocol AudioIOControlling: Sendable {
    func create(
        aggregate: AggregateDeviceResource,
        tap: ProcessTapResource,
        output: AudioDeviceSnapshot,
        maxFrames: UInt32
    ) async throws -> AudioIOResource
    func startCapture(_ resource: AudioIOResource) async throws -> AudioIOResource
    func createOutput(_ resource: AudioIOResource) async throws -> AudioIOResource
    func startOutput(_ resource: AudioIOResource) async throws -> AudioIOResource
    func stop(_ resource: AudioIOResource) async throws -> AudioIOResource
    func destroy(_ resource: AudioIOResource) async throws
    func snapshot(_ resource: AudioIOResource) async throws -> AudioIOBridgeSnapshot
    func signalProbes(_ resource: AudioIOResource) async throws -> [AudioSignalProbeWindow]
}

struct SystemAudioDeviceIOOperations: AudioDeviceIOOperations {
    func createCaptureIOProc(
        deviceID: AudioObjectID,
        bridge: OpaquePointer,
        registration: inout OpaquePointer?
    ) -> OSStatus {
        EAUAudioIORegistrationCreate(deviceID, bridge, EAUAudioIORegistrationCapture, &registration)
    }

    func createOutputUnit(
        deviceID: AudioObjectID,
        bridge: OpaquePointer,
        sampleRate: Double,
        channelCount: UInt32,
        maximumFrames: UInt32,
        outputUnit: inout OpaquePointer?
    ) -> OSStatus {
        EAUAudioOutputUnitCreate(
            deviceID, bridge, sampleRate, channelCount, maximumFrames, &outputUnit
        )
    }

    func startCapture(registration: OpaquePointer) -> OSStatus {
        EAUAudioIORegistrationStart(registration)
    }

    func stopCapture(registration: OpaquePointer) -> OSStatus {
        EAUAudioIORegistrationStop(registration)
    }

    func destroyCapture(registration: OpaquePointer) -> OSStatus {
        EAUAudioIORegistrationDestroy(registration)
    }

    func startOutput(outputUnit: OpaquePointer) -> OSStatus {
        EAUAudioOutputUnitStart(outputUnit)
    }

    func stopOutput(outputUnit: OpaquePointer) -> OSStatus {
        EAUAudioOutputUnitStop(outputUnit)
    }

    func destroyOutput(outputUnit: OpaquePointer) -> OSStatus {
        EAUAudioOutputUnitDestroy(outputUnit)
    }

    func outputDiagnostics(outputUnit: OpaquePointer) -> Result<AudioOutputUnitDiagnostics, AudioIOError> {
        var value = EAUAudioOutputUnitDiagnostics()
        let status = EAUAudioOutputUnitGetDiagnostics(outputUnit, &value)
        guard status == noErr else {
            return .failure(.lifecycle(operation: "Read physical output AUHAL diagnostics", status: status))
        }
        return .success(AudioOutputUnitDiagnostics(
            componentSubType: value.componentSubType,
            currentDevice: value.currentDevice,
            deviceFormat: value.deviceFormat,
            clientFormat: value.clientFormat,
            maximumFrames: value.maximumFrames,
            isRunning: value.isRunningStatus == noErr && value.isRunning != 0,
            volume: value.volumeStatus == noErr ? value.volume : nil,
            isRunningStatus: value.isRunningStatus,
            volumeStatus: value.volumeStatus
        ))
    }
}

actor AudioIOController: AudioIOControlling {
    static let mvpOutputGain = AudioMVPOutputPolicy.gain
    static let mvpOutputLimit = AudioMVPOutputPolicy.limit

    private final class State: @unchecked Sendable {
        enum Operation: String {
            case idle
            case startingCapture
            case creatingOutput
            case startingOutput
            case stopping
            case destroying
        }

        let bridge: OpaquePointer
        var captureRegistration: OpaquePointer?
        var outputRegistration: OpaquePointer?
        var captureStarted = false
        var outputStarted = false
        let outputDeviceID: AudioObjectID
        let sampleRate: Double
        let channelCount: UInt32
        let maximumFrames: UInt32
        var operation = Operation.idle

        init(
            bridge: OpaquePointer,
            capture: OpaquePointer,
            outputDeviceID: AudioObjectID,
            sampleRate: Double,
            channelCount: UInt32,
            maximumFrames: UInt32
        ) {
            self.bridge = bridge
            captureRegistration = capture
            self.outputDeviceID = outputDeviceID
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.maximumFrames = maximumFrames
        }
    }

    private let operations: any AudioDeviceIOOperations
    private let debugLogger: any AudioDebugLogging
    private var states: [UUID: State] = [:]

    init(
        operations: any AudioDeviceIOOperations = SystemAudioDeviceIOOperations(),
        debugLogger: any AudioDebugLogging = AudioDebugLogger.shared
    ) {
        self.operations = operations
        self.debugLogger = debugLogger
    }

    func create(
        aggregate: AggregateDeviceResource,
        tap: ProcessTapResource,
        output: AudioDeviceSnapshot,
        maxFrames: UInt32
    ) async throws -> AudioIOResource {
        guard aggregate.descriptor.generation == tap.descriptor.generation,
              aggregate.descriptor.generation == output.generation else {
            throw AudioIOError.invalidFormat("resource generations do not match")
        }
        let format = aggregate.inputFormat
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mBitsPerChannel == 32,
              format.mFramesPerPacket == 1,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            throw AudioIOError.invalidFormat("capture aggregate is not 32-bit Float LPCM")
        }
        guard abs(aggregate.nominalSampleRate - output.nominalSampleRate) < 0.5,
              abs(format.mSampleRate - aggregate.nominalSampleRate) < 0.5 else {
            throw AudioIOError.invalidFormat(
                "capture aggregate rate \(format.mSampleRate) does not match output \(output.nominalSampleRate); M0 has no realtime resampler"
            )
        }
        let inputChannels = aggregate.inputLayout.buffers.map(\.channelCount)
        let outputChannels = [output.outputLayout.totalChannelCount]
        guard aggregate.tapUIDs == [tap.uid], aggregate.tapUID == tap.uid else {
            throw AudioIOError.invalidFormat("capture aggregate does not contain the expected tap UID")
        }
        guard aggregate.outputDeviceUID == output.uid else {
            throw AudioIOError.invalidFormat("output snapshot UID does not match the capture generation")
        }
        guard aggregate.inputLayout.totalChannelCount == format.mChannelsPerFrame,
              aggregate.inputLayout.totalChannelCount == output.outputLayout.totalChannelCount else {
            throw AudioIOError.incompatibleBufferLayouts(input: inputChannels, output: outputChannels)
        }
        guard maxFrames > 0, maxFrames <= UInt32.max / 8,
              output.bufferFrameSize > 0, output.bufferFrameSize <= maxFrames else {
            throw AudioIOError.invalidFormat("maximum frame capacity is invalid")
        }

        let ringCapacity = maxFrames * 8
        let primeFrames = min(ringCapacity, output.bufferFrameSize * 2)
        let targetBacklogFrames = max(maxFrames, primeFrames)
        let bridge = inputChannels.withUnsafeBufferPointer { input in
            outputChannels.withUnsafeBufferPointer { output in
                EAUAudioIOBridgeCreate(
                    input.baseAddress, UInt32(input.count),
                    output.baseAddress, UInt32(output.count),
                    UInt32(MemoryLayout<Float>.size), maxFrames,
                    ringCapacity, primeFrames, targetBacklogFrames,
                    Self.mvpOutputGain, Self.mvpOutputLimit
                )
            }
        }
        guard let bridge else { throw AudioIOError.bridgeCreationFailed }

        var captureRegistration: OpaquePointer?
        let status = operations.createCaptureIOProc(
            deviceID: aggregate.objectID,
            bridge: bridge,
            registration: &captureRegistration
        )
        guard status == noErr, let captureRegistration else {
            EAUAudioIOBridgeDestroy(bridge)
            throw AudioIOError.lifecycle(
                operation: "Create tap capture IOProc",
                status: status == noErr ? kAudioHardwareBadObjectError : status
            )
        }

        let ownershipToken = UUID()
        states[ownershipToken] = State(
            bridge: bridge,
            capture: captureRegistration,
            outputDeviceID: output.objectID,
            sampleRate: output.nominalSampleRate,
            channelCount: output.outputLayout.totalChannelCount,
            maximumFrames: maxFrames
        )
        return AudioIOResource(
            descriptor: AudioResourceDescriptor(
                ownershipToken: ownershipToken,
                generation: aggregate.descriptor.generation,
                kind: .ioProc,
                objectID: aggregate.objectID,
                persistentUID: aggregate.uid
            ),
            captureRegistration: captureRegistration,
            outputRegistration: nil,
            bridge: bridge,
            sampleRate: format.mSampleRate,
            isCaptureStarted: false,
            isOutputStarted: false
        )
    }

    func startCapture(_ resource: AudioIOResource) async throws -> AudioIOResource {
        let state = try ownedState(for: resource)
        try begin(.startingCapture, on: state)
        defer { endOperation(on: state, ownershipToken: resource.ownershipToken) }
        if !state.captureStarted, let registration = state.captureRegistration {
            let status = operations.startCapture(registration: registration)
            guard status == noErr else {
                throw AudioIOError.lifecycle(operation: "Start tap capture IOProc", status: status)
            }
            state.captureStarted = true
        }
        return resourceValue(resource, state: state)
    }

    func createOutput(_ resource: AudioIOResource) async throws -> AudioIOResource {
        let state = try ownedState(for: resource)
        try begin(.creatingOutput, on: state)
        defer { endOperation(on: state, ownershipToken: resource.ownershipToken) }
        guard state.captureStarted else {
            throw AudioIOError.invalidFormat("tap capture IOProc must be running before output creation")
        }
        guard state.outputRegistration == nil else { return resourceValue(resource, state: state) }

        var outputRegistration: OpaquePointer?
        let status = operations.createOutputUnit(
            deviceID: state.outputDeviceID,
            bridge: state.bridge,
            sampleRate: state.sampleRate,
            channelCount: state.channelCount,
            maximumFrames: state.maximumFrames,
            outputUnit: &outputRegistration
        )
        if let outputRegistration {
            state.outputRegistration = outputRegistration
        }
        guard status == noErr, let outputRegistration else {
            throw AudioIOError.lifecycle(
                operation: "Create physical output AUHAL after capture start",
                status: status == noErr ? kAudioHardwareBadObjectError : status
            )
        }

        let diagnostics = try validatedOutputDiagnostics(
            outputRegistration: outputRegistration,
            state: state,
            requireRunning: false
        )
        await debugLogger.log("auhal.configured", generation: resource.descriptor.generation, fields: [
            "componentSubType": fourCC(diagnostics.componentSubType),
            "requestedDevice": "\(state.outputDeviceID)",
            "currentDevice": "\(diagnostics.currentDevice)",
            "requestedRate": "\(state.sampleRate)",
            "deviceFormat": describe(diagnostics.deviceFormat),
            "clientFormat": describe(diagnostics.clientFormat),
            "maximumFrames": "\(diagnostics.maximumFrames)",
            "isRunning": diagnosticRunning(diagnostics),
            "volume": diagnosticVolume(diagnostics),
            "isRunningStatus": "\(diagnostics.isRunningStatus)",
            "volumeStatus": "\(diagnostics.volumeStatus)",
            "gain": "\(Self.mvpOutputGain)",
            "limit": "\(Self.mvpOutputLimit)"
        ])
        return resourceValue(resource, state: state)
    }

    func startOutput(_ resource: AudioIOResource) async throws -> AudioIOResource {
        let state = try ownedState(for: resource)
        try begin(.startingOutput, on: state)
        defer { endOperation(on: state, ownershipToken: resource.ownershipToken) }
        guard state.captureStarted else {
            throw AudioIOError.invalidFormat("tap capture IOProc must be running before output start")
        }
        guard let outputRegistration = state.outputRegistration else {
            throw AudioIOError.invalidFormat("physical output AUHAL must be created before output start")
        }
        if !state.outputStarted {
            let status = operations.startOutput(outputUnit: outputRegistration)
            guard status == noErr else {
                throw AudioIOError.lifecycle(operation: "Start physical output AUHAL", status: status)
            }
            state.outputStarted = true
        }
        let diagnostics = try validatedOutputDiagnostics(
            outputRegistration: outputRegistration,
            state: state,
            requireRunning: true
        )
        await debugLogger.log("auhal.started", generation: resource.descriptor.generation, fields: [
            "isRunning": diagnosticRunning(diagnostics),
            "volume": diagnosticVolume(diagnostics),
            "isRunningStatus": "\(diagnostics.isRunningStatus)",
            "volumeStatus": "\(diagnostics.volumeStatus)"
        ])
        return resourceValue(resource, state: state)
    }

    func stop(_ resource: AudioIOResource) async throws -> AudioIOResource {
        let state = try ownedState(for: resource)
        try begin(.stopping, on: state)
        defer { endOperation(on: state, ownershipToken: resource.ownershipToken) }
        var firstError: AudioIOError?
        if state.outputStarted, let registration = state.outputRegistration {
            EAUAudioIOBridgeRequestFadeOut(state.bridge, 512)
            for _ in 0..<200 where !EAUAudioIOBridgeIsFadeComplete(state.bridge) {
                try await Task.sleep(for: .milliseconds(1))
            }
            let status = operations.stopOutput(outputUnit: registration)
            if status == noErr {
                state.outputStarted = false
                await logOutputDiagnostics(
                    event: "auhal.stopped",
                    generation: resource.descriptor.generation,
                    outputRegistration: registration
                )
            } else {
                firstError = .lifecycle(operation: "Stop physical output AUHAL", status: status)
            }
        }
        if state.captureStarted, let registration = state.captureRegistration {
            let status = operations.stopCapture(registration: registration)
            if status == noErr {
                state.captureStarted = false
            } else if firstError == nil {
                firstError = .lifecycle(operation: "Stop tap capture IOProc", status: status)
            }
        }
        EAUAudioIOBridgeBeginStopping(state.bridge)
        if let firstError { throw firstError }
        return resourceValue(resource, state: state)
    }

    func destroy(_ resource: AudioIOResource) async throws {
        let state = try ownedState(for: resource)
        try begin(.destroying, on: state)
        defer { endOperation(on: state, ownershipToken: resource.ownershipToken) }
        guard !state.outputStarted, !state.captureStarted else {
            throw AudioIOError.invalidFormat("both IOProcs must be stopped before destroy")
        }
        EAUAudioIOBridgeBeginStopping(state.bridge)
        for _ in 0..<100 where !EAUAudioIOBridgeIsQuiescent(state.bridge) {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard EAUAudioIOBridgeIsQuiescent(state.bridge) else {
            throw AudioIOError.callbacksDidNotQuiesce
        }
        if let registration = state.outputRegistration {
            let status = operations.destroyOutput(outputUnit: registration)
            guard status == noErr else {
                throw AudioIOError.lifecycle(operation: "Destroy physical output AUHAL", status: status)
            }
            state.outputRegistration = nil
        }
        if let registration = state.captureRegistration {
            let status = operations.destroyCapture(registration: registration)
            guard status == noErr else {
                throw AudioIOError.lifecycle(operation: "Destroy tap capture IOProc", status: status)
            }
            state.captureRegistration = nil
        }
        states.removeValue(forKey: resource.ownershipToken)
        EAUAudioIOBridgeDestroy(state.bridge)
    }

    func snapshot(_ resource: AudioIOResource) throws -> AudioIOBridgeSnapshot {
        let state = try ownedState(for: resource)
        let value = EAUAudioIOBridgeGetSnapshot(state.bridge)
        return AudioIOBridgeSnapshot(
            callbackCount: value.captureCallbackCount,
            frameCount: value.capturedFrames,
            nonZeroSampleCount: value.nonZeroSampleCount,
            lastHostTime: value.captureLastHostTime,
            maxObservedFrames: value.maxObservedFrames,
            faultFlags: value.faultFlags,
            inFlightCallbacks: value.inFlightCallbacks,
            captureCallbackCount: value.captureCallbackCount,
            outputCallbackCount: value.outputCallbackCount,
            capturedFrames: value.capturedFrames,
            renderedFrames: value.renderedFrames,
            renderedNonZeroSampleCount: value.renderedNonZeroSampleCount,
            underrunBlocks: value.underrunBlocks,
            overflowFrames: value.overflowFrames,
            droppedFrames: value.droppedFrames,
            primingBlocks: value.primingBlocks,
            backlogCorrections: value.backlogCorrections,
            renderActionSilenceInputBlocks: value.renderActionSilenceInputBlocks,
            renderActionSilenceClearedBlocks: value.renderActionSilenceClearedBlocks,
            outputSilenceBlocks: value.outputSilenceBlocks,
            outputNonSilenceBlocks: value.outputNonSilenceBlocks,
            ringFillFrames: value.ringFillFrames,
            fadeComplete: value.fadeComplete
        )
    }

    func signalProbes(_ resource: AudioIOResource) async throws -> [AudioSignalProbeWindow] {
        let state = try ownedState(for: resource)
        let frameCapacity = EAUAudioIOBridgeGetSignalProbeFrameCapacity(state.bridge)
        let channelCount = EAUAudioIOBridgeGetSignalProbeChannelCount(state.bridge)
        guard frameCapacity > 0, channelCount > 0,
              frameCapacity <= UInt32.max / channelCount else { return [] }
        let sampleCapacity = frameCapacity * channelCount

        return AudioSignalStage.allCases.compactMap { stage in
            var samples = [Float](repeating: 0, count: Int(sampleCapacity))
            var metadata = EAUAudioSignalProbeMetadata()
            let copied = samples.withUnsafeMutableBufferPointer { buffer in
                EAUAudioIOBridgeCopyLatestSignalProbe(
                    state.bridge, stage.bridgeValue, buffer.baseAddress,
                    sampleCapacity, &metadata
                )
            }
            guard copied > 0, metadata.frameCount > 0, metadata.channelCount == channelCount else {
                return nil
            }
            samples.removeSubrange(Int(copied)..<samples.count)
            return AudioSignalProbeWindow(
                stage: stage,
                sequence: metadata.sequence,
                hostTime: metadata.hostTime,
                droppedFrames: metadata.droppedFrames,
                frameCount: metadata.frameCount,
                channelCount: metadata.channelCount,
                sampleRate: resource.sampleRate,
                samples: samples
            )
        }
    }

    private func ownedState(for resource: AudioIOResource) throws -> State {
        guard let state = states[resource.ownershipToken], state.bridge == resource.bridge else {
            throw AudioIOError.staleResource
        }
        return state
    }

    private func begin(_ operation: State.Operation, on state: State) throws {
        guard state.operation == .idle else {
            throw AudioIOError.operationInProgress(state.operation.rawValue)
        }
        state.operation = operation
    }

    private func endOperation(on state: State, ownershipToken: UUID) {
        guard states[ownershipToken] === state else { return }
        state.operation = .idle
    }

    private func resourceValue(_ resource: AudioIOResource, state: State) -> AudioIOResource {
        AudioIOResource(
            descriptor: resource.descriptor,
            captureRegistration: resource.captureRegistration,
            outputRegistration: state.outputRegistration,
            bridge: state.bridge,
            sampleRate: resource.sampleRate,
            isCaptureStarted: state.captureStarted,
            isOutputStarted: state.outputStarted
        )
    }


    private func describe(_ format: AudioStreamBasicDescription) -> String {
        "rate=\(format.mSampleRate),format=\(fourCC(format.mFormatID)),flags=0x\(String(format.mFormatFlags, radix: 16)),bytesPerFrame=\(format.mBytesPerFrame),channels=\(format.mChannelsPerFrame),bits=\(format.mBitsPerChannel)"
    }

    private func validatedOutputDiagnostics(
        outputRegistration: OpaquePointer,
        state: State,
        requireRunning: Bool
    ) throws -> AudioOutputUnitDiagnostics {
        let diagnostics: AudioOutputUnitDiagnostics
        switch operations.outputDiagnostics(outputUnit: outputRegistration) {
        case let .success(value):
            diagnostics = value
        case let .failure(error):
            throw error
        }

        guard diagnostics.componentSubType == kAudioUnitSubType_DefaultOutput else {
            throw AudioIOError.invalidFormat(
                "output component is \(fourCC(diagnostics.componentSubType)), expected DefaultOutput"
            )
        }
        guard diagnostics.currentDevice == state.outputDeviceID else {
            throw AudioIOError.invalidFormat(
                "output unit is bound to device \(diagnostics.currentDevice), expected \(state.outputDeviceID)"
            )
        }
        guard abs(diagnostics.deviceFormat.mSampleRate - state.sampleRate) < 0.5,
              diagnostics.deviceFormat.mChannelsPerFrame == state.channelCount else {
            throw AudioIOError.invalidFormat(
                "physical output format does not match the selected device snapshot"
            )
        }
        guard state.channelCount <= UInt32.max / UInt32(MemoryLayout<Float>.size) else {
            throw AudioIOError.invalidFormat("output channel count overflows the Float32 frame width")
        }
        let expectedBytesPerFrame = state.channelCount * UInt32(MemoryLayout<Float>.size)
        let client = diagnostics.clientFormat
        guard client.mFormatID == kAudioFormatLinearPCM,
              client.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              client.mFormatFlags & kAudioFormatFlagIsPacked != 0,
              client.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              client.mBitsPerChannel == 32,
              client.mFramesPerPacket == 1,
              client.mChannelsPerFrame == state.channelCount,
              client.mBytesPerFrame == expectedBytesPerFrame,
              client.mBytesPerPacket == expectedBytesPerFrame,
              abs(client.mSampleRate - state.sampleRate) < 0.5 else {
            throw AudioIOError.invalidFormat(
                "output client format does not match the interleaved Float32 ring contract"
            )
        }
        guard diagnostics.maximumFrames >= state.maximumFrames else {
            throw AudioIOError.invalidFormat(
                "output maximum frames \(diagnostics.maximumFrames) is below required \(state.maximumFrames)"
            )
        }
        if requireRunning {
            guard diagnostics.isRunningStatus == noErr, diagnostics.isRunning else {
                throw AudioIOError.invalidFormat("output unit did not report a running state after start")
            }
        }
        return diagnostics
    }

    private func logOutputDiagnostics(
        event: String,
        generation: AudioGeneration,
        outputRegistration: OpaquePointer
    ) async {
        switch operations.outputDiagnostics(outputUnit: outputRegistration) {
        case let .success(diagnostics):
            await debugLogger.log(event, generation: generation, fields: [
                "isRunning": diagnosticRunning(diagnostics),
                "volume": diagnosticVolume(diagnostics),
                "isRunningStatus": "\(diagnostics.isRunningStatus)",
                "volumeStatus": "\(diagnostics.volumeStatus)"
            ])
        case let .failure(error):
            await debugLogger.log("\(event).diagnostics.failed", generation: generation, fields: [
                "error": error.localizedDescription
            ])
        }
    }

    private func diagnosticRunning(_ diagnostics: AudioOutputUnitDiagnostics) -> String {
        diagnostics.isRunningStatus == noErr ? "\(diagnostics.isRunning)" : "unavailable"
    }

    private func diagnosticVolume(_ diagnostics: AudioOutputUnitDiagnostics) -> String {
        diagnostics.volume.map { String($0) } ?? "unavailable"
    }
}
