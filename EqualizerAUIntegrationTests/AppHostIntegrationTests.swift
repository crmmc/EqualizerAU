import CoreAudio
import AudioToolbox
import XCTest
@testable import EqualizerAU

final class AppHostIntegrationTests: XCTestCase {
    func testExplicitHALOutputCanBindCurrentPhysicalDeviceWithoutStartingAudio() async throws {
        let output = try await DefaultOutputDeviceDiscovery().snapshot(
            generation: AudioGeneration(rawValue: 33)
        )
        let channels = output.outputLayout.totalChannelCount
        let maxFrames = max(
            output.bufferFrameSize,
            UInt32(output.bufferFrameSizeRange.upperBound.rounded(.up))
        )
        let layouts = [channels]
        let bridge = layouts.withUnsafeBufferPointer { input in
            layouts.withUnsafeBufferPointer { rendered in
                EAUAudioIOBridgeCreate(
                    input.baseAddress, 1, rendered.baseAddress, 1,
                    UInt32(MemoryLayout<Float>.size), maxFrames,
                    maxFrames * 8, output.bufferFrameSize * 2, maxFrames * 2,
                    0.05, 0.10
                )
            }
        }
        let unwrappedBridge = try XCTUnwrap(bridge)
        defer { EAUAudioIOBridgeDestroy(unwrappedBridge) }

        var outputUnit: OpaquePointer?
        XCTAssertEqual(
            EAUAudioHALOutputUnitCreate(
                output.objectID, unwrappedBridge, output.nominalSampleRate,
                channels, maxFrames, &outputUnit
            ),
            noErr
        )
        let unwrappedOutputUnit = try XCTUnwrap(outputUnit)
        var diagnostics = EAUAudioOutputUnitDiagnostics()
        XCTAssertEqual(
            EAUAudioOutputUnitGetDiagnostics(unwrappedOutputUnit, &diagnostics),
            noErr
        )
        XCTAssertEqual(diagnostics.componentSubType, kAudioUnitSubType_HALOutput)
        XCTAssertEqual(diagnostics.currentDevice, output.objectID)
        XCTAssertEqual(diagnostics.clientFormat.mSampleRate, output.nominalSampleRate)
        XCTAssertEqual(diagnostics.clientFormat.mChannelsPerFrame, channels)
        XCTAssertEqual(diagnostics.isRunningStatus, noErr)
        XCTAssertEqual(diagnostics.isRunning, 0)
        XCTAssertEqual(EAUAudioOutputUnitDestroy(unwrappedOutputUnit), noErr)
    }

    func testAUHALCanBindCurrentOutputWithoutStartingAudio() async throws {
        let generation = AudioGeneration(rawValue: 31)
        let output = try await DefaultOutputDeviceDiscovery().snapshot(generation: generation)
        let channels = output.outputLayout.totalChannelCount
        let maxFrames = max(output.bufferFrameSize, UInt32(output.bufferFrameSizeRange.upperBound.rounded(.up)))
        let layouts = [channels]
        let bridge = layouts.withUnsafeBufferPointer { input in
            layouts.withUnsafeBufferPointer { rendered in
                EAUAudioIOBridgeCreate(
                    input.baseAddress, 1, rendered.baseAddress, 1,
                    UInt32(MemoryLayout<Float>.size), maxFrames,
                    maxFrames * 8, output.bufferFrameSize * 2, maxFrames * 2,
                    0.05, 0.10
                )
            }
        }
        let unwrappedBridge = try XCTUnwrap(bridge)
        defer { EAUAudioIOBridgeDestroy(unwrappedBridge) }

        var outputUnit: OpaquePointer?
        let createStatus = EAUAudioOutputUnitCreate(
            output.objectID, unwrappedBridge, output.nominalSampleRate,
            channels, maxFrames, &outputUnit
        )
        XCTAssertEqual(createStatus, noErr)
        let unwrappedOutputUnit = try XCTUnwrap(outputUnit)

        var diagnostics = EAUAudioOutputUnitDiagnostics()
        XCTAssertEqual(
            EAUAudioOutputUnitGetDiagnostics(unwrappedOutputUnit, &diagnostics),
            noErr
        )
        XCTAssertEqual(diagnostics.componentSubType, kAudioUnitSubType_DefaultOutput)
        XCTAssertEqual(diagnostics.currentDevice, output.objectID)
        XCTAssertEqual(diagnostics.clientFormat.mSampleRate, output.nominalSampleRate)
        XCTAssertEqual(diagnostics.clientFormat.mChannelsPerFrame, channels)
        XCTAssertEqual(diagnostics.clientFormat.mFormatID, kAudioFormatLinearPCM)
        XCTAssertNotEqual(
            diagnostics.clientFormat.mFormatFlags & kAudioFormatFlagIsFloat,
            0
        )
        XCTAssertEqual(
            diagnostics.clientFormat.mBytesPerFrame,
            UInt32(MemoryLayout<Float>.size) * channels
        )
        XCTAssertGreaterThan(diagnostics.deviceFormat.mSampleRate, 0)
        XCTAssertGreaterThan(diagnostics.deviceFormat.mChannelsPerFrame, 0)
        XCTAssertGreaterThanOrEqual(diagnostics.maximumFrames, maxFrames)
        XCTAssertEqual(diagnostics.isRunningStatus, noErr)
        XCTAssertEqual(diagnostics.isRunning, 0)
        if diagnostics.volumeStatus == noErr {
            XCTAssertGreaterThanOrEqual(diagnostics.volume, 0)
            XCTAssertLessThanOrEqual(diagnostics.volume, 1)
        }
        XCTAssertEqual(EAUAudioOutputUnitDestroy(unwrappedOutputUnit), noErr)
    }

    func testSyntheticToneCallbackIsBoundedRepeatableAndSilentAfterCompletionWithoutStartingAudio() async throws {
        let output = try await DefaultOutputDeviceDiscovery().snapshot(
            generation: AudioGeneration(rawValue: 32)
        )
        let channels = output.outputLayout.totalChannelCount
        let maximumFrames = max(
            output.bufferFrameSize,
            UInt32(output.bufferFrameSizeRange.upperBound.rounded(.up))
        )
        let renderFrames: UInt32 = 512
        let durationFrames: UInt32 = renderFrames * 2
        var tone: OpaquePointer?
        XCTAssertEqual(
            EAUSyntheticToneOutputCreate(
                output.objectID, output.nominalSampleRate, channels, maximumFrames,
                660, 0.02, durationFrames, 32, &tone
            ),
            noErr
        )
        let unwrappedTone = try XCTUnwrap(tone)
        defer { _ = EAUSyntheticToneOutputDestroy(unwrappedTone) }

        var flags = AudioUnitRenderActionFlags(rawValue: 0)
        let first = renderSyntheticTone(
            unwrappedTone, flags: &flags, channels: channels, frames: renderFrames
        )
        XCTAssertFalse(flags.contains(.unitRenderAction_OutputIsSilence))
        XCTAssertGreaterThan(first.map(abs).max() ?? 0, 0)
        XCTAssertLessThanOrEqual(first.map(abs).max() ?? 1, 0.02)

        flags = AudioUnitRenderActionFlags(rawValue: 0)
        let second = renderSyntheticTone(
            unwrappedTone, flags: &flags, channels: channels, frames: renderFrames
        )
        XCTAssertFalse(flags.contains(.unitRenderAction_OutputIsSilence))
        XCTAssertGreaterThan(second.map(abs).max() ?? 0, 0)

        flags = AudioUnitRenderActionFlags(rawValue: 0)
        let afterCompletion = renderSyntheticTone(
            unwrappedTone, flags: &flags, channels: channels, frames: renderFrames
        )
        XCTAssertTrue(flags.contains(.unitRenderAction_OutputIsSilence))
        XCTAssertTrue(afterCompletion.allSatisfy { $0 == 0 })

        let completed = EAUSyntheticToneOutputGetSnapshot(unwrappedTone)
        XCTAssertTrue(completed.completed)
        XCTAssertEqual(completed.renderedFrames, UInt64(durationFrames))
        XCTAssertEqual(completed.nonSilenceBlocks, 2)
        XCTAssertEqual(completed.silenceBlocks, 1)
        XCTAssertEqual(completed.faultFlags, 0)

        XCTAssertEqual(EAUSyntheticToneOutputReset(unwrappedTone), noErr)
        flags = AudioUnitRenderActionFlags(rawValue: 0)
        let repeatedFirst = renderSyntheticTone(
            unwrappedTone, flags: &flags, channels: channels, frames: renderFrames
        )
        XCTAssertEqual(repeatedFirst, first)
        XCTAssertFalse(flags.contains(.unitRenderAction_OutputIsSilence))
    }

    func testSyntheticSignalCallbackCopiesExactPrecomputedNonceWithoutStartingAudio() async throws {
        let output = try await DefaultOutputDeviceDiscovery().snapshot(
            generation: AudioGeneration(rawValue: 33)
        )
        let channels = output.outputLayout.totalChannelCount
        let maximumFrames = max(
            output.bufferFrameSize,
            UInt32(output.bufferFrameSizeRange.upperBound.rounded(.up))
        )
        let nonce: [Float] = [0.0, 0.01, -0.02, 0.03, -0.04, 0.005, -0.0075, 0.0125]
        let original = nonce
        let creationCount = EAUAudioOutputUnitGetCreationCount()
        var signal: OpaquePointer?
        XCTAssertEqual(
            nonce.withUnsafeBufferPointer {
                EAUSyntheticSignalOutputCreate(
                    output.objectID, output.nominalSampleRate, channels, maximumFrames,
                    $0.baseAddress, UInt32($0.count), &signal
                )
            },
            noErr
        )
        let unwrappedSignal = try XCTUnwrap(signal)
        defer { _ = EAUSyntheticToneOutputDestroy(unwrappedSignal) }

        XCTAssertEqual(EAUAudioOutputUnitGetCreationCount(), creationCount + 1)
        XCTAssertEqual(nonce, original)
        var flags = AudioUnitRenderActionFlags(rawValue: 0)
        let rendered = renderSyntheticTone(
            unwrappedSignal,
            flags: &flags,
            channels: channels,
            frames: UInt32(nonce.count)
        )
        for frame in nonce.indices {
            for channel in 0..<Int(channels) {
                XCTAssertEqual(rendered[frame * Int(channels) + channel], nonce[frame])
            }
        }
        XCTAssertFalse(flags.contains(.unitRenderAction_OutputIsSilence))
        XCTAssertEqual(EAUSyntheticToneOutputGetSnapshot(unwrappedSignal).faultFlags, 0)
    }

    @MainActor
    func testCommandEntryPointsRemainSafeBeforeAudioResourcesExist() async {
        let model = AppModel(lifecycle: AudioLifecycleController(pipeline: NeverCompletingPipeline()))

        model.start()
        model.retry()
        model.stop()

        for _ in 0..<100 where model.audioState != .stopped {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(model.audioState, .stopped)
        XCTAssertNil(model.lastError)
    }

    func testDefaultOutputDeviceSnapshotCanBeReadRepeatedly() async throws {
        let discovery = DefaultOutputDeviceDiscovery()

        let first = try await discovery.snapshot(generation: AudioGeneration(rawValue: 1))
        let second = try await discovery.snapshot(generation: AudioGeneration(rawValue: 2))

        XCTAssertFalse(first.uid.isEmpty)
        XCTAssertFalse(first.name.isEmpty)
        XCTAssertTrue(first.isAlive)
        XCTAssertGreaterThan(first.nominalSampleRate, 0)
        XCTAssertGreaterThan(first.outputChannelCount, 0)
        XCTAssertGreaterThan(first.bufferFrameSize, 0)
        XCTAssertEqual(first.uid, second.uid)
        XCTAssertEqual(first.name, second.name)
        XCTAssertNotEqual(first.generation, second.generation)
    }

    func testProcessTapCreateDestroyCyclesLeaveNoOwnedTapIDs() async throws {
        let controller = ProcessTapController()
        let reader = HALPropertyReader()
        var createdIDs: [AudioObjectID] = []

        for generation in 1...3 {
            let resource = try await controller.create(
                configuration: ProcessTapConfiguration(
                    generation: AudioGeneration(rawValue: UInt64(generation)),
                    name: "EqualizerAU M0 Integration Tap \(generation)",
                    muteBehavior: .unmuted
                )
            )
            createdIDs.append(resource.objectID)
            XCTAssertTrue(try currentTapIDs(reader: reader).contains(resource.objectID))
            try await controller.destroy(resource)
            let disappeared = try await waitUntilTapDisappears(
                resource.objectID,
                reader: reader
            )
            XCTAssertTrue(
                disappeared,
                "Destroyed tap did not leave the HAL tap list within the bounded wait"
            )
        }

        let remainingTapIDs = try currentTapIDs(reader: reader)
        XCTAssertTrue(Set(createdIDs).isDisjoint(with: remainingTapIDs))
    }

    func testPrivateTapOnlyAggregateLeavesNoOwnedDeviceID() async throws {
        let generation = AudioGeneration(rawValue: 100)
        let reader = HALPropertyReader()
        let discovery = DefaultOutputDeviceDiscovery()
        let tapController = ProcessTapController()
        let aggregateController = AggregateDeviceController()
        let output = try await discovery.snapshot(generation: generation)
        var tap: ProcessTapResource?
        var aggregate: AggregateDeviceResource?

        do {
            let createdTap = try await tapController.create(
                configuration: ProcessTapConfiguration(
                    generation: generation,
                    name: "EqualizerAU M0 Aggregate Integration Tap",
                    muteBehavior: .unmuted,
                    outputDeviceUID: output.uid,
                    outputStreamIndex: 0
                )
            )
            tap = createdTap
            let createdAggregate = try await aggregateController.create(
                configuration: AggregateDeviceConfiguration(generation: generation),
                output: output,
                tap: createdTap
            )
            aggregate = createdAggregate

            XCTAssertEqual(createdAggregate.outputDeviceUID, output.uid)
            XCTAssertEqual(createdAggregate.tapUIDs, [createdTap.uid])
            XCTAssertGreaterThan(createdAggregate.inputLayout.totalChannelCount, 0)
            XCTAssertTrue(try currentDeviceIDs(reader: reader).contains(createdAggregate.objectID))

            try await aggregateController.destroy(createdAggregate)
            aggregate = nil
            let aggregateDisappeared = try await waitUntilDeviceDisappears(
                createdAggregate.objectID,
                reader: reader
            )
            XCTAssertTrue(
                aggregateDisappeared,
                "Destroyed aggregate did not leave the HAL device list within the bounded wait"
            )
            try await tapController.destroy(createdTap)
            tap = nil
            let tapDisappeared = try await waitUntilTapDisappears(
                createdTap.objectID,
                reader: reader
            )
            XCTAssertTrue(
                tapDisappeared,
                "Destroyed tap did not leave the HAL tap list within the bounded wait"
            )
        } catch {
            if let aggregate {
                try? await aggregateController.destroy(aggregate)
            }
            if let tap {
                try? await tapController.destroy(tap)
            }
            throw error
        }
    }

    private func waitUntilTapDisappears(
        _ tapID: AudioObjectID,
        reader: HALPropertyReader
    ) async throws -> Bool {
        for _ in 0..<100 {
            if try !currentTapIDs(reader: reader).contains(tapID) {
                return true
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func waitUntilDeviceDisappears(
        _ deviceID: AudioObjectID,
        reader: HALPropertyReader
    ) async throws -> Bool {
        for _ in 0..<100 {
            if try !currentDeviceIDs(reader: reader).contains(deviceID) {
                return true
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func currentTapIDs(reader: HALPropertyReader) throws -> Set<AudioObjectID> {
        let data = try reader.readData(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: HALPropertyAddress(selector: kAudioHardwarePropertyTapList),
            operation: "Read kAudioHardwarePropertyTapList",
            allowEmpty: true
        )
        guard data.count.isMultiple(of: MemoryLayout<AudioObjectID>.size) else {
            throw HALStatusError(
                operation: "Validate kAudioHardwarePropertyTapList data size",
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: HALPropertyAddress(selector: kAudioHardwarePropertyTapList),
                status: kAudio_ParamError
            )
        }
        return data.withUnsafeBytes { bytes in
            Set(stride(from: 0, to: bytes.count, by: MemoryLayout<AudioObjectID>.size).map {
                bytes.loadUnaligned(fromByteOffset: $0, as: AudioObjectID.self)
            })
        }
    }


    private func currentDeviceIDs(reader: HALPropertyReader) throws -> Set<AudioObjectID> {
        let data = try reader.readData(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: HALPropertyAddress(selector: kAudioHardwarePropertyDevices),
            operation: "Read kAudioHardwarePropertyDevices",
            allowEmpty: true
        )
        guard data.count.isMultiple(of: MemoryLayout<AudioObjectID>.size) else {
            throw HALStatusError(
                operation: "Validate kAudioHardwarePropertyDevices data size",
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: HALPropertyAddress(selector: kAudioHardwarePropertyDevices),
                status: kAudio_ParamError
            )
        }
        return data.withUnsafeBytes { bytes in
            Set(stride(from: 0, to: bytes.count, by: MemoryLayout<AudioObjectID>.size).map {
                bytes.loadUnaligned(fromByteOffset: $0, as: AudioObjectID.self)
            })
        }
    }
}

private func renderSyntheticTone(
    _ tone: OpaquePointer,
    flags: inout AudioUnitRenderActionFlags,
    channels: UInt32,
    frames: UInt32
) -> [Float] {
    let sampleCount = Int(channels * frames)
    let samples = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
    samples.initialize(repeating: 1, count: sampleCount)
    defer {
        samples.deinitialize(count: sampleCount)
        samples.deallocate()
    }
    let list = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
    list.initialize(to: AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
            mNumberChannels: channels,
            mDataByteSize: UInt32(sampleCount * MemoryLayout<Float>.size),
            mData: samples
        )
    ))
    defer {
        list.deinitialize(count: 1)
        list.deallocate()
    }
    _ = EAUSyntheticToneOutputRender(tone, &flags, nil, frames, list)
    return Array(UnsafeBufferPointer(start: samples, count: sampleCount))
}

private actor NeverCompletingPipeline: AudioPipelineManaging {
    private var active: AudioPipelineSnapshot?

    func start(generation: AudioGeneration) async throws -> AudioPipelineSnapshot {
        try await Task.sleep(for: .milliseconds(10))
        let snapshot = AudioPipelineSnapshot(
            generation: generation,
            outputDeviceName: "Test Output",
            tapUID: "test.tap",
            tapFormat: "48000 Hz, 2 ch, 'lpcm'",
            diagnostics: AudioIOBridgeSnapshot(
                callbackCount: 0,
                frameCount: 0,
                nonZeroSampleCount: 0,
                lastHostTime: 0,
                maxObservedFrames: 0,
                faultFlags: 0,
                inFlightCallbacks: 0
            )
        )
        active = snapshot
        return snapshot
    }

    func stop() {
        active = nil
    }

    func snapshot() -> AudioPipelineSnapshot? {
        active
    }
}
