import CoreAudio
import Foundation

struct M1SystemAudioIOOperations: M1AudioIOOperations, @unchecked Sendable {
    func createHost(
        configuration: M1AudioIOHostConfiguration,
        runtime: M1RuntimeHandleLease
    ) throws -> M1AudioIOHostHandle {
        var capabilities = EAUM1AudioIOHostCapabilities()
        guard EAUM1AudioIOHostGetCapabilities(&capabilities) == EAUM1StatusOK,
              capabilities.booleanAtomicsLockFree != 0,
              capabilities.counterAtomicsLockFree != 0
        else {
            throw M1AudioIOError.invalidConfiguration("required audio host atomics are not lock-free")
        }
        let channelCounts = try configuration.inputChannelCounts.map { value -> UInt32 in
            guard let result = UInt32(exactly: value), result > 0 else {
                throw M1AudioIOError.invalidConfiguration("invalid capture channel count")
            }
            return result
        }
        guard let channelCount = UInt32(exactly: configuration.channelCount),
              let maximumFrames = UInt32(exactly: configuration.maximumFrameCount),
              let ringCapacity = UInt32(exactly: configuration.ringCapacityFrames),
              let primeFrames = UInt32(exactly: configuration.primeFrames),
              let targetBacklog = UInt32(exactly: configuration.targetBacklogFrames)
        else {
            throw M1AudioIOError.invalidConfiguration("host dimensions exceed the ABI")
        }

        var pointer: OpaquePointer?
        let status = channelCounts.withUnsafeBufferPointer { counts in
            var description = EAUM1AudioIOHostDescription(
                runtime: runtime.pointer,
                inputBufferCount: UInt32(counts.count),
                inputChannelCounts: counts.baseAddress,
                channelCount: channelCount,
                maximumFrameCount: maximumFrames,
                ringCapacityFrames: ringCapacity,
                primeFrames: primeFrames,
                targetBacklogFrames: targetBacklog
            )
            return EAUM1AudioIOHostCreate(&description, &pointer)
        }
        guard status == EAUM1StatusOK, let pointer else {
            throw M1AudioIOError.invalidConfiguration("EAUM1AudioIOHostCreate failed: \(status)")
        }
        return M1AudioIOHostHandle(pointer: pointer)
    }

    func beginStopping(_ host: M1AudioIOHostHandle) {
        EAUM1AudioIOHostBeginStopping(host.pointer)
    }

    func requestFadeOut(_ host: M1AudioIOHostHandle, frameCount: Int) {
        guard let count = UInt32(exactly: frameCount) else { return }
        EAUM1AudioIOHostRequestFadeOut(host.pointer, count)
    }

    func isFadeComplete(_ host: M1AudioIOHostHandle) -> Bool {
        EAUM1AudioIOHostIsFadeComplete(host.pointer) != 0
    }

    func isQuiescent(_ host: M1AudioIOHostHandle) -> Bool {
        EAUM1AudioIOHostIsQuiescent(host.pointer) != 0
    }

    func hostDiagnostics(_ host: M1AudioIOHostHandle) throws -> M1AudioIOHostCounters {
        var value = EAUM1AudioIOHostDiagnostics()
        let status = EAUM1AudioIOHostCopyDiagnostics(host.pointer, &value)
        guard status == EAUM1StatusOK else {
            throw M1AudioIOError.invalidState("audio host diagnostics failed: \(status)")
        }
        return M1AudioIOHostCounters(
            capturedFrames: value.capturedFrameCount,
            renderedFrames: value.renderedFrameCount,
            overflowedBlocks: value.overflowedBlockCount,
            underrunBlocks: value.underrunBlockCount,
            droppedBacklogFrames: value.droppedBacklogFrameCount,
            invalidCallbacks: value.invalidCallbackCount,
            overlappingRenderCallbacks: value.overlappingRenderCallbackCount
        )
    }

    func destroyHost(_ host: M1AudioIOHostHandle) {
        EAUM1AudioIOHostDestroy(host.pointer)
    }

    func createCapture(
        aggregateDeviceID: UInt32,
        host: M1AudioIOHostHandle
    ) throws -> M1CaptureHandle {
        var pointer: OpaquePointer?
        let status = EAUM1CaptureRegistrationCreate(aggregateDeviceID, host.pointer, &pointer)
        guard status == noErr, let pointer else {
            throw M1CoreAudioStatusError(operation: "Create capture IOProc", status: status)
        }
        return M1CaptureHandle(pointer: pointer)
    }

    func startCapture(_ capture: M1CaptureHandle) throws {
        try requireNoErr(EAUM1CaptureRegistrationStart(capture.pointer), "Start capture IOProc")
    }

    func stopCapture(_ capture: M1CaptureHandle) throws {
        try requireNoErr(EAUM1CaptureRegistrationStop(capture.pointer), "Stop capture IOProc")
    }

    func destroyCapture(_ capture: M1CaptureHandle) throws {
        try requireNoErr(EAUM1CaptureRegistrationDestroy(capture.pointer), "Destroy capture IOProc")
    }

    func createOutput(
        deviceID: UInt32,
        sampleRate: Double,
        channelCount: Int,
        maximumFrameCount: Int,
        host: M1AudioIOHostHandle
    ) throws -> M1OutputHandle {
        guard let channels = UInt32(exactly: channelCount),
              let maximumFrames = UInt32(exactly: maximumFrameCount)
        else {
            throw M1AudioIOError.invalidConfiguration("output dimensions exceed the ABI")
        }
        var pointer: OpaquePointer?
        let status = EAUM1OutputRegistrationCreate(
            deviceID,
            sampleRate,
            channels,
            maximumFrames,
            host.pointer,
            &pointer
        )
        if status != noErr, let pointer {
            let output = M1OutputHandle(pointer: pointer)
            throw M1RetainedOutputCreationError(
                output: output,
                underlying: M1CoreAudioStatusError(operation: "Create DefaultOutput", status: status)
            )
        }
        guard status == noErr, let pointer else {
            throw M1CoreAudioStatusError(operation: "Create DefaultOutput", status: status)
        }
        return M1OutputHandle(pointer: pointer)
    }

    func startOutput(_ output: M1OutputHandle) throws {
        try requireNoErr(EAUM1OutputRegistrationStart(output.pointer), "Start DefaultOutput")
    }

    func stopOutput(_ output: M1OutputHandle) throws {
        try requireNoErr(EAUM1OutputRegistrationStop(output.pointer), "Stop DefaultOutput")
    }

    func outputDiagnostics(_ output: M1OutputHandle) throws -> M1OutputHostDiagnostics {
        var value = EAUM1OutputDiagnostics()
        try requireNoErr(
            EAUM1OutputRegistrationCopyDiagnostics(output.pointer, &value),
            "Read DefaultOutput diagnostics"
        )
        return M1OutputHostDiagnostics(
            currentDeviceID: value.currentDevice,
            currentDeviceUID: try deviceUID(value.currentDevice),
            deviceSampleRate: value.deviceFormat.mSampleRate,
            deviceChannelCount: Int(value.deviceFormat.mChannelsPerFrame),
            deviceFormatSupported: isSupportedFloat32PCM(value.deviceFormat),
            clientSampleRate: value.clientFormat.mSampleRate,
            clientChannelCount: Int(value.clientFormat.mChannelsPerFrame),
            clientFormatSupported: isSupportedFloat32PCM(value.clientFormat),
            maximumFrameCount: Int(value.maximumFrames),
            isRunning: value.isRunning != 0
        )
    }

    func destroyOutput(_ output: M1OutputHandle) throws {
        try requireNoErr(EAUM1OutputRegistrationDestroy(output.pointer), "Destroy DefaultOutput")
    }

    private func requireNoErr(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw M1CoreAudioStatusError(operation: operation, status: status)
        }
    }

    private func isSupportedFloat32PCM(_ value: AudioStreamBasicDescription) -> Bool {
        let nativeEndian: Bool
        #if _endian(little)
        nativeEndian = value.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
        #else
        nativeEndian = value.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        #endif
        return value.mSampleRate.isFinite
            && value.mSampleRate > 0
            && value.mFormatID == kAudioFormatLinearPCM
            && value.mBitsPerChannel == 32
            && value.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && value.mFormatFlags & kAudioFormatFlagIsPacked != 0
            && nativeEndian
            && value.mFramesPerPacket == 1
            && value.mChannelsPerFrame > 0
            && value.mBytesPerFrame == value.mChannelsPerFrame * UInt32(MemoryLayout<Float>.size)
            && value.mBytesPerPacket == value.mBytesPerFrame
    }

    private func deviceUID(_ objectID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr, let value else {
            throw M1CoreAudioStatusError(operation: "Read bound output UID", status: status)
        }
        return value.takeRetainedValue() as String
    }
}

struct M1SystemRuntimeFactory: M1RuntimeCreating, @unchecked Sendable {
    func createRuntime(
        bridgeGeneration: UInt64,
        initialState: M1RuntimeInitialState,
        maximumFrameCount: Int,
        sampleRate: Double
    ) throws -> M1RuntimeHandleLease {
        let channelCount = initialState.linearGainsByChannel.count
        guard let channels = UInt32(exactly: channelCount), channels > 0,
              let maximumFrames = UInt32(exactly: maximumFrameCount), maximumFrames > 0,
              !initialState.bufferChannelCounts.isEmpty,
              initialState.bufferChannelCounts.reduce(0, +) == channelCount,
              sampleRate.isFinite, sampleRate > 0
        else {
            throw M1AudioIOError.invalidConfiguration("invalid Runtime dimensions")
        }
        var capabilities = EAUM1RuntimeCapabilities()
        guard EAUM1RuntimeGetCapabilities(&capabilities) == EAUM1StatusOK,
              capabilities.activePreparedPointerLockFree != 0,
              capabilities.callbackStateLockFree != 0,
              capabilities.effectsEnabledLockFree != 0,
              capabilities.diagnosticCountersLockFree != 0
        else {
            throw M1AudioIOError.invalidConfiguration("required Runtime atomics are not lock-free")
        }

        let gains = initialState.linearGainsByChannel
        var prepared: OpaquePointer?
        let preparedStatus = gains.withUnsafeBufferPointer { values in
            EAUM1PreparedStateCreate(values.baseAddress, channels, &prepared)
        }
        guard preparedStatus == EAUM1StatusOK, prepared != nil else {
            throw M1AudioIOError.invalidConfiguration("initial Prepared creation failed")
        }
        var runtime: OpaquePointer?
        var channelCounts = try initialState.bufferChannelCounts.map { count -> UInt32 in
            guard let value = UInt32(exactly: count), value > 0 else {
                throw M1AudioIOError.invalidConfiguration("invalid Runtime buffer topology")
            }
            return value
        }
        let createStatus = channelCounts.withUnsafeBufferPointer { counts in
            var description = EAUM1RuntimeDescription(
                sampleRate: sampleRate,
                maximumFrameCount: maximumFrames,
                bufferCount: UInt32(channelCounts.count),
                channelCounts: counts.baseAddress,
                effectsEnabled: initialState.effectsEnabled ? 1 : 0
            )
            return EAUM1RuntimeCreate(&description, &prepared, &runtime)
        }
        if createStatus != EAUM1StatusOK {
            EAUM1PreparedStateDestroy(prepared)
        }
        guard createStatus == EAUM1StatusOK, prepared == nil, let runtime else {
            throw M1AudioIOError.invalidConfiguration("Runtime creation failed: \(createStatus)")
        }
        return M1RuntimeHandleLease(bridgeGeneration: bridgeGeneration, pointer: runtime)
    }

    func destroyRuntime(_ runtime: M1RuntimeHandleLease) {
        EAUM1RuntimeDestroy(runtime.pointer)
    }
}
