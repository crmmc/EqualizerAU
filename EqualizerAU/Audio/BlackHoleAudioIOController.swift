import AudioToolbox
import CoreAudio
import Foundation

enum AudioMVPOutputPolicy {
    static let gain: Float = 0.25118864
    static let limit: Float = 0.25118864
}

struct BlackHoleAudioIOResource: @unchecked Sendable {
    let descriptor: AudioResourceDescriptor
    let physicalOutputDeviceID: AudioObjectID
    let physicalOutputUID: String
    let bridge: OpaquePointer
    let captureRegistration: OpaquePointer
    let outputUnit: OpaquePointer
    let sampleRate: Double
    private(set) var isCaptureStarted: Bool
    private(set) var isOutputStarted: Bool

    var generation: AudioGeneration { descriptor.generation }
}

enum BlackHoleAudioIOError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration(String)
    case bridgeCreationFailed
    case lifecycle(operation: String, status: OSStatus)
    case outputReadbackMismatch(field: String, expected: String, actual: String)
    case fadeDidNotComplete
    case bridgeResetFailed
    case callbacksDidNotQuiesce

    var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(reason):
            return "BlackHole route configuration is invalid: \(reason)."
        case .bridgeCreationFailed:
            return "Unable to allocate the fixed-capacity BlackHole audio bridge."
        case let .lifecycle(operation, status):
            return "\(operation) failed: OSStatus \(status) (\(fourCC(UInt32(bitPattern: status))))"
        case let .outputReadbackMismatch(field, expected, actual):
            return "Physical HALOutput \(field) mismatch: expected '\(expected)', got '\(actual)'."
        case .fadeDidNotComplete:
            return "Physical output did not finish its bounded fade before route restoration."
        case .bridgeResetFailed:
            return "The BlackHole audio bridge could not reset after endpoint preflight."
        case .callbacksDidNotQuiesce:
            return "BlackHole route callbacks did not quiesce after both devices stopped."
        }
    }
}

protocol BlackHoleAudioIOOperations: Sendable {
    func createCapture(
        deviceID: AudioObjectID,
        bridge: OpaquePointer,
        registration: inout OpaquePointer?
    ) -> OSStatus
    func createPhysicalOutput(
        deviceID: AudioObjectID,
        bridge: OpaquePointer,
        sampleRate: Double,
        channelCount: UInt32,
        maximumFrames: UInt32,
        outputUnit: inout OpaquePointer?
    ) -> OSStatus
    func startCapture(_ registration: OpaquePointer) -> OSStatus
    func stopCapture(_ registration: OpaquePointer) -> OSStatus
    func destroyCapture(_ registration: OpaquePointer) -> OSStatus
    func startOutput(_ outputUnit: OpaquePointer) -> OSStatus
    func stopOutput(_ outputUnit: OpaquePointer) -> OSStatus
    func destroyOutput(_ outputUnit: OpaquePointer) -> OSStatus
    func outputDiagnostics(_ outputUnit: OpaquePointer) -> Result<AudioOutputUnitDiagnostics, BlackHoleAudioIOError>
}

struct SystemBlackHoleAudioIOOperations: BlackHoleAudioIOOperations {
    func createCapture(
        deviceID: AudioObjectID,
        bridge: OpaquePointer,
        registration: inout OpaquePointer?
    ) -> OSStatus {
        EAUAudioIORegistrationCreate(
            deviceID, bridge, EAUAudioIORegistrationCapture, &registration
        )
    }

    func createPhysicalOutput(
        deviceID: AudioObjectID,
        bridge: OpaquePointer,
        sampleRate: Double,
        channelCount: UInt32,
        maximumFrames: UInt32,
        outputUnit: inout OpaquePointer?
    ) -> OSStatus {
        EAUAudioHALOutputUnitCreate(
            deviceID, bridge, sampleRate, channelCount, maximumFrames, &outputUnit
        )
    }

    func startCapture(_ registration: OpaquePointer) -> OSStatus {
        EAUAudioIORegistrationStart(registration)
    }

    func stopCapture(_ registration: OpaquePointer) -> OSStatus {
        EAUAudioIORegistrationStop(registration)
    }

    func destroyCapture(_ registration: OpaquePointer) -> OSStatus {
        EAUAudioIORegistrationDestroy(registration)
    }

    func startOutput(_ outputUnit: OpaquePointer) -> OSStatus {
        EAUAudioOutputUnitStart(outputUnit)
    }

    func stopOutput(_ outputUnit: OpaquePointer) -> OSStatus {
        EAUAudioOutputUnitStop(outputUnit)
    }

    func destroyOutput(_ outputUnit: OpaquePointer) -> OSStatus {
        EAUAudioOutputUnitDestroy(outputUnit)
    }

    func outputDiagnostics(
        _ outputUnit: OpaquePointer
    ) -> Result<AudioOutputUnitDiagnostics, BlackHoleAudioIOError> {
        var value = EAUAudioOutputUnitDiagnostics()
        let status = EAUAudioOutputUnitGetDiagnostics(outputUnit, &value)
        guard status == noErr else {
            return .failure(.lifecycle(operation: "Read physical HALOutput diagnostics", status: status))
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

protocol BlackHoleAudioIOControlling: Sendable {
    func create(
        blackHole: BlackHoleDeviceSnapshot,
        physicalOutput: AudioDeviceSnapshot,
        maximumFrames: UInt32
    ) async throws -> BlackHoleAudioIOResource
    func startOutput(_ resource: BlackHoleAudioIOResource) async throws -> BlackHoleAudioIOResource
    func startCapture(_ resource: BlackHoleAudioIOResource) async throws -> BlackHoleAudioIOResource
    func reset(_ resource: BlackHoleAudioIOResource) async throws
    func fadeOut(_ resource: BlackHoleAudioIOResource) async throws
    func cancelFadeOut(_ resource: BlackHoleAudioIOResource) async
    func stopOutput(_ resource: BlackHoleAudioIOResource) async throws -> BlackHoleAudioIOResource
    func stopCapture(_ resource: BlackHoleAudioIOResource) async throws -> BlackHoleAudioIOResource
    func destroy(_ resource: BlackHoleAudioIOResource) async throws
    func snapshot(_ resource: BlackHoleAudioIOResource) async -> AudioIOBridgeSnapshot
}

actor BlackHoleAudioIOController: BlackHoleAudioIOControlling {
    private struct PendingOutputCleanup: @unchecked Sendable {
        let bridge: OpaquePointer
        let outputUnit: OpaquePointer
    }

    private final class State: @unchecked Sendable {
        var capture: OpaquePointer?
        var output: OpaquePointer?
        var captureStarted = false
        var outputStarted = false

        init(capture: OpaquePointer, output: OpaquePointer) {
            self.capture = capture
            self.output = output
        }
    }

    private let operations: any BlackHoleAudioIOOperations
    private let debugLogger: any AudioDebugLogging
    private var states: [UInt: State] = [:]
    private var pendingOutputCleanup: [PendingOutputCleanup] = []

    init(
        operations: any BlackHoleAudioIOOperations = SystemBlackHoleAudioIOOperations(),
        debugLogger: any AudioDebugLogging = AudioDebugLogger.shared
    ) {
        self.operations = operations
        self.debugLogger = debugLogger
    }

    func create(
        blackHole: BlackHoleDeviceSnapshot,
        physicalOutput: AudioDeviceSnapshot,
        maximumFrames: UInt32
    ) async throws -> BlackHoleAudioIOResource {
        try retryPendingOutputCleanup()
        try validate(
            blackHole: blackHole,
            physicalOutput: physicalOutput,
            maximumFrames: maximumFrames
        )

        let inputChannels = blackHole.inputLayout.buffers.map(\.channelCount)
        let outputChannels = [physicalOutput.outputLayout.totalChannelCount]
        let ringCapacity = maximumFrames * 8
        let primeFrames = min(ringCapacity, physicalOutput.bufferFrameSize * 2)
        let targetBacklogFrames = max(maximumFrames, primeFrames)
        let bridge = inputChannels.withUnsafeBufferPointer { input in
            outputChannels.withUnsafeBufferPointer { output in
                EAUAudioIOBridgeCreate(
                    input.baseAddress, UInt32(input.count),
                    output.baseAddress, UInt32(output.count),
                    UInt32(MemoryLayout<Float>.size), maximumFrames,
                    ringCapacity, primeFrames, targetBacklogFrames,
                    AudioMVPOutputPolicy.gain, AudioMVPOutputPolicy.limit
                )
            }
        }
        guard let bridge else { throw BlackHoleAudioIOError.bridgeCreationFailed }

        var outputUnit: OpaquePointer?
        var status = operations.createPhysicalOutput(
            deviceID: physicalOutput.objectID,
            bridge: bridge,
            sampleRate: physicalOutput.nominalSampleRate,
            channelCount: physicalOutput.outputLayout.totalChannelCount,
            maximumFrames: maximumFrames,
            outputUnit: &outputUnit
        )
        guard status == noErr, let outputUnit else {
            EAUAudioIOBridgeDestroy(bridge)
            throw BlackHoleAudioIOError.lifecycle(
                operation: "Create explicit physical HALOutput",
                status: status == noErr ? kAudioHardwareBadObjectError : status
            )
        }

        do {
            let diagnostics = try outputDiagnostics(outputUnit)
            try validateOutputReadback(
                diagnostics,
                physicalOutput: physicalOutput,
                maximumFrames: maximumFrames
            )
            await debugLogger.log("blackhole.io.configured", generation: blackHole.generation, fields: [
                "blackHoleDevice": "\(blackHole.objectID)",
                "physicalDevice": "\(physicalOutput.objectID)",
                "componentSubType": fourCC(diagnostics.componentSubType),
                "sampleRate": "\(physicalOutput.nominalSampleRate)",
                "channels": "\(physicalOutput.outputLayout.totalChannelCount)",
                "maximumFrames": "\(maximumFrames)",
                "ringCapacity": "\(ringCapacity)",
                "primeFrames": "\(primeFrames)"
            ])
        } catch {
            let cleanupStatus = operations.destroyOutput(outputUnit)
            if cleanupStatus == noErr {
                EAUAudioIOBridgeDestroy(bridge)
            } else {
                pendingOutputCleanup.append(PendingOutputCleanup(
                    bridge: bridge,
                    outputUnit: outputUnit
                ))
            }
            throw error
        }

        var capture: OpaquePointer?
        status = operations.createCapture(
            deviceID: blackHole.objectID,
            bridge: bridge,
            registration: &capture
        )
        guard status == noErr, let capture else {
            let cleanupStatus = operations.destroyOutput(outputUnit)
            if cleanupStatus == noErr {
                EAUAudioIOBridgeDestroy(bridge)
            } else {
                pendingOutputCleanup.append(PendingOutputCleanup(
                    bridge: bridge,
                    outputUnit: outputUnit
                ))
            }
            throw BlackHoleAudioIOError.lifecycle(
                operation: cleanupStatus == noErr
                    ? "Create BlackHole capture IOProc"
                    : "Create BlackHole capture IOProc; retain HALOutput after cleanup failure",
                status: cleanupStatus == noErr
                    ? (status == noErr ? kAudioHardwareBadObjectError : status)
                    : cleanupStatus
            )
        }

        states[key(bridge)] = State(capture: capture, output: outputUnit)
        return BlackHoleAudioIOResource(
            descriptor: AudioResourceDescriptor(
                generation: blackHole.generation,
                kind: .ioProc,
                objectID: blackHole.objectID,
                persistentUID: blackHole.uid
            ),
            physicalOutputDeviceID: physicalOutput.objectID,
            physicalOutputUID: physicalOutput.uid,
            bridge: bridge,
            captureRegistration: capture,
            outputUnit: outputUnit,
            sampleRate: blackHole.nominalSampleRate,
            isCaptureStarted: false,
            isOutputStarted: false
        )
    }

    func startOutput(
        _ resource: BlackHoleAudioIOResource
    ) async throws -> BlackHoleAudioIOResource {
        guard let state = states[key(resource.bridge)] else { return resource }
        if !state.outputStarted, let output = state.output {
            let status = operations.startOutput(output)
            guard status == noErr else {
                throw BlackHoleAudioIOError.lifecycle(
                    operation: "Start explicit physical HALOutput", status: status
                )
            }
            state.outputStarted = true
        }
        return resourceValue(resource, state: state)
    }

    func startCapture(
        _ resource: BlackHoleAudioIOResource
    ) async throws -> BlackHoleAudioIOResource {
        guard let state = states[key(resource.bridge)] else { return resource }
        if !state.captureStarted, let capture = state.capture {
            let status = operations.startCapture(capture)
            guard status == noErr else {
                throw BlackHoleAudioIOError.lifecycle(
                    operation: "Start BlackHole capture IOProc", status: status
                )
            }
            state.captureStarted = true
        }
        return resourceValue(resource, state: state)
    }

    func fadeOut(_ resource: BlackHoleAudioIOResource) async throws {
        guard let state = states[key(resource.bridge)], state.outputStarted else { return }
        EAUAudioIOBridgeRequestFadeOut(resource.bridge, 512)
        for _ in 0..<200 where !EAUAudioIOBridgeIsFadeComplete(resource.bridge) {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard EAUAudioIOBridgeIsFadeComplete(resource.bridge) else {
            throw BlackHoleAudioIOError.fadeDidNotComplete
        }
    }

    func reset(_ resource: BlackHoleAudioIOResource) async throws {
        guard let state = states[key(resource.bridge)] else { return }
        guard !state.outputStarted, !state.captureStarted else {
            throw BlackHoleAudioIOError.invalidConfiguration(
                "both BlackHole route IO endpoints must stop before bridge reset"
            )
        }
        for _ in 0..<100 where !EAUAudioIOBridgeIsQuiescent(resource.bridge) {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard EAUAudioIOBridgeIsQuiescent(resource.bridge) else {
            throw BlackHoleAudioIOError.callbacksDidNotQuiesce
        }
        guard EAUAudioIOBridgeReset(resource.bridge) else {
            throw BlackHoleAudioIOError.bridgeResetFailed
        }
    }

    func cancelFadeOut(_ resource: BlackHoleAudioIOResource) {
        EAUAudioIOBridgeCancelFadeOut(resource.bridge)
    }

    func stopOutput(
        _ resource: BlackHoleAudioIOResource
    ) async throws -> BlackHoleAudioIOResource {
        guard let state = states[key(resource.bridge)] else { return resource }
        if state.outputStarted, let output = state.output {
            let status = operations.stopOutput(output)
            guard status == noErr else {
                throw BlackHoleAudioIOError.lifecycle(
                    operation: "Stop explicit physical HALOutput", status: status
                )
            }
            state.outputStarted = false
        }
        return resourceValue(resource, state: state)
    }

    func stopCapture(
        _ resource: BlackHoleAudioIOResource
    ) async throws -> BlackHoleAudioIOResource {
        guard let state = states[key(resource.bridge)] else { return resource }
        if state.captureStarted, let capture = state.capture {
            let status = operations.stopCapture(capture)
            guard status == noErr else {
                throw BlackHoleAudioIOError.lifecycle(
                    operation: "Stop BlackHole capture IOProc", status: status
                )
            }
            state.captureStarted = false
        }
        return resourceValue(resource, state: state)
    }

    func destroy(_ resource: BlackHoleAudioIOResource) async throws {
        let stateKey = key(resource.bridge)
        guard let state = states[stateKey] else { return }
        guard !state.outputStarted, !state.captureStarted else {
            throw BlackHoleAudioIOError.invalidConfiguration(
                "both BlackHole route IO endpoints must stop before destroy"
            )
        }
        EAUAudioIOBridgeBeginStopping(resource.bridge)
        for _ in 0..<100 where !EAUAudioIOBridgeIsQuiescent(resource.bridge) {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard EAUAudioIOBridgeIsQuiescent(resource.bridge) else {
            throw BlackHoleAudioIOError.callbacksDidNotQuiesce
        }
        if let output = state.output {
            let status = operations.destroyOutput(output)
            guard status == noErr else {
                throw BlackHoleAudioIOError.lifecycle(
                    operation: "Destroy explicit physical HALOutput", status: status
                )
            }
            state.output = nil
        }
        if let capture = state.capture {
            let status = operations.destroyCapture(capture)
            guard status == noErr else {
                throw BlackHoleAudioIOError.lifecycle(
                    operation: "Destroy BlackHole capture IOProc", status: status
                )
            }
            state.capture = nil
        }
        states.removeValue(forKey: stateKey)
        EAUAudioIOBridgeDestroy(resource.bridge)
    }

    func snapshot(_ resource: BlackHoleAudioIOResource) -> AudioIOBridgeSnapshot {
        let value = EAUAudioIOBridgeGetSnapshot(resource.bridge)
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

    private func validate(
        blackHole: BlackHoleDeviceSnapshot,
        physicalOutput: AudioDeviceSnapshot,
        maximumFrames: UInt32
    ) throws {
        guard blackHole.generation == physicalOutput.generation else {
            throw BlackHoleAudioIOError.invalidConfiguration("resource generations do not match")
        }
        guard blackHole.uid == BlackHoleDeviceSnapshot.expectedUID,
              blackHole.transportType == kAudioDeviceTransportTypeVirtual,
              blackHole.isAlive else {
            throw BlackHoleAudioIOError.invalidConfiguration("BlackHole identity was not validated")
        }
        guard blackHole.inputLayout.totalChannelCount == 2,
              blackHole.inputFormat.mChannelsPerFrame == 2,
              physicalOutput.outputLayout.totalChannelCount == 2 else {
            throw BlackHoleAudioIOError.invalidConfiguration("M0 route requires stereo input and output")
        }
        guard blackHole.inputFormat.mFormatID == kAudioFormatLinearPCM,
              blackHole.inputFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              blackHole.inputFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              blackHole.inputFormat.mBitsPerChannel == 32,
              blackHole.inputFormat.mBytesPerFrame == 8 else {
            throw BlackHoleAudioIOError.invalidConfiguration(
                "BlackHole input is not interleaved 32-bit Float LPCM"
            )
        }
        guard abs(blackHole.nominalSampleRate - physicalOutput.nominalSampleRate) < 0.5 else {
            throw BlackHoleAudioIOError.invalidConfiguration(
                "BlackHole rate \(blackHole.nominalSampleRate) does not match physical output \(physicalOutput.nominalSampleRate); the short proof has no SRC"
            )
        }
        guard maximumFrames > 0,
              maximumFrames <= UInt32.max / 8,
              physicalOutput.bufferFrameSize > 0,
              physicalOutput.bufferFrameSize <= maximumFrames else {
            throw BlackHoleAudioIOError.invalidConfiguration("maximum frame capacity is invalid")
        }
    }

    private func outputDiagnostics(
        _ outputUnit: OpaquePointer
    ) throws -> AudioOutputUnitDiagnostics {
        switch operations.outputDiagnostics(outputUnit) {
        case let .success(value): return value
        case let .failure(error): throw error
        }
    }

    private func validateOutputReadback(
        _ diagnostics: AudioOutputUnitDiagnostics,
        physicalOutput: AudioDeviceSnapshot,
        maximumFrames: UInt32
    ) throws {
        try requireReadback(
            field: "component subtype",
            expected: fourCC(kAudioUnitSubType_HALOutput),
            actual: fourCC(diagnostics.componentSubType)
        )
        try requireReadback(
            field: "device",
            expected: "\(physicalOutput.objectID)",
            actual: "\(diagnostics.currentDevice)"
        )
        let client = diagnostics.clientFormat
        let clientValid = client.mFormatID == kAudioFormatLinearPCM
            && client.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && client.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            && client.mChannelsPerFrame == 2
            && client.mBitsPerChannel == 32
            && client.mBytesPerFrame == 8
            && abs(client.mSampleRate - physicalOutput.nominalSampleRate) < 0.5
        guard clientValid else {
            throw BlackHoleAudioIOError.outputReadbackMismatch(
                field: "client format",
                expected: "interleaved Float32 stereo at \(physicalOutput.nominalSampleRate)",
                actual: describe(client)
            )
        }
        guard diagnostics.maximumFrames >= maximumFrames else {
            throw BlackHoleAudioIOError.outputReadbackMismatch(
                field: "maximum frames",
                expected: ">= \(maximumFrames)",
                actual: "\(diagnostics.maximumFrames)"
            )
        }
    }

    private func requireReadback(field: String, expected: String, actual: String) throws {
        guard expected == actual else {
            throw BlackHoleAudioIOError.outputReadbackMismatch(
                field: field, expected: expected, actual: actual
            )
        }
    }

    private func describe(_ format: AudioStreamBasicDescription) -> String {
        "rate=\(format.mSampleRate),format=\(fourCC(format.mFormatID)),flags=0x\(String(format.mFormatFlags, radix: 16)),bytesPerFrame=\(format.mBytesPerFrame),channels=\(format.mChannelsPerFrame),bits=\(format.mBitsPerChannel)"
    }

    private func retryPendingOutputCleanup() throws {
        guard !pendingOutputCleanup.isEmpty else { return }
        var remaining: [PendingOutputCleanup] = []
        var firstStatus: OSStatus?
        for pending in pendingOutputCleanup {
            let status = operations.destroyOutput(pending.outputUnit)
            if status == noErr {
                EAUAudioIOBridgeDestroy(pending.bridge)
            } else {
                remaining.append(pending)
                if firstStatus == nil { firstStatus = status }
            }
        }
        pendingOutputCleanup = remaining
        if let firstStatus {
            throw BlackHoleAudioIOError.lifecycle(
                operation: "Retry retained explicit HALOutput cleanup",
                status: firstStatus
            )
        }
    }

    private func key(_ bridge: OpaquePointer) -> UInt {
        UInt(bitPattern: bridge)
    }

    private func resourceValue(
        _ resource: BlackHoleAudioIOResource,
        state: State
    ) -> BlackHoleAudioIOResource {
        BlackHoleAudioIOResource(
            descriptor: resource.descriptor,
            physicalOutputDeviceID: resource.physicalOutputDeviceID,
            physicalOutputUID: resource.physicalOutputUID,
            bridge: resource.bridge,
            captureRegistration: resource.captureRegistration,
            outputUnit: resource.outputUnit,
            sampleRate: resource.sampleRate,
            isCaptureStarted: state.captureStarted,
            isOutputStarted: state.outputStarted
        )
    }
}
