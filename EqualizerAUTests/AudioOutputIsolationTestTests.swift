import CoreAudio
import XCTest
@testable import EqualizerAU

final class AudioOutputIsolationTestTests: XCTestCase {
    func testColdParityStartsCaptureBeforeCreatingOnlyOutputAndCorrelatesNonce() async throws {
        let events = IsolationEventRecorder()
        let delays = IsolationDelayRecorder()
        let controller = makeController(events: events, delays: delays)

        let result = try await controller.run()

        XCTAssertEqual(result.frequency, 660)
        XCTAssertEqual(result.amplitude, 0.02)
        XCTAssertTrue(result.activeTap.tone.completed)
        XCTAssertEqual(result.processIdentity, AudioOutputIsolationProcessIdentity(
            tapCreation: 135,
            afterOutputInitialization: 135,
            afterFirstRender: 135,
            outputOwnershipAfterFirstRender: CoreAudioProcessOutputState(
                processObjectID: 135,
                isRunningOutput: true,
                outputDeviceIDs: [94]
            ),
            activeOutputProcessesBeforeTap: [],
            activeOutputProcessesAfterFirstRender: [135],
            activeOutputProcessesBeforeStop: [135]
        ))
        XCTAssertEqual(result.aggregateSampleRate, 48_000)
        XCTAssertEqual(result.attribution.verdict, .detected)
        XCTAssertGreaterThan(result.attribution.capture.challengeCorrelation, 0.99)
        XCTAssertEqual(delays.values, [.milliseconds(250)])
        XCTAssertEqual(events.values, [
            "output.count", "output", "tap.identity", "tap.activeOutputs", "tap.create",
            "aggregate.create", "drain.create", "drain.start",
            "signal.begin", "signal.create", "output.count", "tone.diagnostics", "tap.identity",
            "tone.start", "tap.identity", "tap.outputState", "tap.activeOutputs",
            "tap.activeOutputs", "tone.stop", "tone.destroy", "signal.end",
            "signal.window.challengeCapture", "drain.stop", "drain.destroy",
            "aggregate.destroy", "tap.destroy"
        ])
    }

    func testChallengeStartFailureCleansTheEntireDependencyChain() async {
        let events = IsolationEventRecorder()
        let controller = makeController(
            events: events,
            operations: IsolationOperationsStub(events: events, startStatus: -50)
        )

        do {
            _ = try await controller.run()
            XCTFail("Expected challenge start to fail")
        } catch {}

        XCTAssertFalse(events.values.contains("tone.stop"))
        XCTAssertTrue(events.values.contains("tone.destroy"))
        XCTAssertTrue(events.values.contains("drain.stop"))
        XCTAssertTrue(events.values.contains("drain.destroy"))
        XCTAssertTrue(events.values.contains("aggregate.destroy"))
        XCTAssertTrue(events.values.contains("tap.destroy"))
    }

    func testRepeatedToneStopFailureRetainsTheStartedOutputAndTapChain() async {
        let events = IsolationEventRecorder()
        let controller = makeController(
            events: events,
            operations: IsolationOperationsStub(events: events, stopToneStatuses: [-50, -50])
        )

        do {
            _ = try await controller.run()
            XCTFail("Expected tone stop to fail")
        } catch {}

        XCTAssertEqual(events.values.filter { $0 == "tone.stop" }.count, 2)
        XCTAssertFalse(events.values.contains("tone.destroy"))
        XCTAssertFalse(events.values.contains("drain.stop"))
        XCTAssertFalse(events.values.contains("aggregate.destroy"))
        XCTAssertFalse(events.values.contains("tap.destroy"))
    }

    func testRepeatedDrainStopFailureRetainsDependencyChain() async {
        let events = IsolationEventRecorder()
        let controller = makeController(
            events: events,
            operations: IsolationOperationsStub(events: events, stopDrainStatuses: [-50, -50])
        )

        do {
            _ = try await controller.run()
            XCTFail("Expected drain stop to fail")
        } catch {}

        XCTAssertEqual(events.values.filter { $0 == "drain.stop" }.count, 2)
        XCTAssertTrue(events.values.contains("tone.destroy"))
        XCTAssertFalse(events.values.contains("drain.destroy"))
        XCTAssertFalse(events.values.contains("aggregate.destroy"))
        XCTAssertFalse(events.values.contains("tap.destroy"))
    }

    func testProcessObjectChangeAfterOutputInitializationFailsBeforeStart() async {
        let events = IsolationEventRecorder()
        let tap = IsolationTapStub(events: events, translatedIDs: [135, 999])
        let controller = makeController(events: events, tapController: tap)

        do {
            _ = try await controller.run()
            XCTFail("Expected process-object invariant to fail")
        } catch let error as AudioOutputIsolationError {
            XCTAssertEqual(error, .processObjectChanged(
                stage: "after DefaultOutput initialization", expected: 135, actual: 999
            ))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertFalse(events.values.contains("tone.start"))
        XCTAssertTrue(events.values.contains("tone.destroy"))
        XCTAssertTrue(events.values.contains("tap.destroy"))
    }

    func testDrainFaultMakesNonceAttributionInconclusive() async throws {
        let events = IsolationEventRecorder()
        let controller = makeController(
            events: events,
            operations: IsolationOperationsStub(
                events: events,
                drainFaultFlags: UInt32(EAUAudioIOFaultLayoutMismatch)
            )
        )

        let result = try await controller.run()

        XCTAssertEqual(result.attribution.verdict, .inconclusive)
        XCTAssertEqual(result.attribution.drainFaultFlags, UInt32(EAUAudioIOFaultLayoutMismatch))
    }

    func testOutputOwnershipMismatchFailsWhileChallengeOutputIsActive() async {
        let events = IsolationEventRecorder()
        let tap = IsolationTapStub(
            events: events,
            outputStates: [CoreAudioProcessOutputState(
                processObjectID: 135,
                isRunningOutput: true,
                outputDeviceIDs: [999]
            )]
        )
        let controller = makeController(events: events, tapController: tap)

        do {
            _ = try await controller.run()
            XCTFail("Expected output-ownership invariant to fail")
        } catch let error as AudioOutputIsolationError {
            XCTAssertEqual(error, .processOutputOwnershipMismatch(
                stage: "after first DefaultOutput render",
                processObjectID: 135,
                expectedDeviceID: 94,
                isRunningOutput: true,
                outputDeviceIDs: [999]
            ))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(events.values.contains("tap.outputState"))
        XCTAssertTrue(events.values.contains("tone.stop"))
        XCTAssertTrue(events.values.contains("tone.destroy"))
        XCTAssertTrue(events.values.contains("tap.destroy"))
    }

    func testProbeRejectsProcessThatAlreadyCreatedAnOutputUnit() async {
        let events = IsolationEventRecorder()
        let controller = makeController(
            events: events,
            operations: IsolationOperationsStub(events: events, initialOutputUnitCount: 1)
        )

        do {
            _ = try await controller.run()
            XCTFail("Expected the cold-process gate to fail")
        } catch let error as AudioOutputIsolationError {
            XCTAssertEqual(error, .outputUnitAlreadyCreated(1))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(events.values, ["output.count"])
    }

    func testProbeRejectsActiveRelayBeforeTapCreation() async {
        let events = IsolationEventRecorder()
        let tap = IsolationTapStub(events: events, activeOutputSets: [[777]])
        let controller = makeController(events: events, tapController: tap)

        do {
            _ = try await controller.run()
            XCTFail("Expected the active relay preflight to fail")
        } catch let error as AudioOutputIsolationError {
            XCTAssertEqual(error, .activeOutputProcessSetMismatch(
                stage: "before Process Tap creation",
                expected: [],
                actual: [777]
            ))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(events.values, [
            "output.count", "output", "tap.identity", "tap.activeOutputs"
        ])
        XCTAssertFalse(events.values.contains("tap.create"))
    }

    func testRelayAppearingDuringChallengeInvalidatesIsolationResult() async {
        let events = IsolationEventRecorder()
        let tap = IsolationTapStub(
            events: events,
            activeOutputSets: [[], [135, 777]]
        )
        let controller = makeController(events: events, tapController: tap)

        do {
            _ = try await controller.run()
            XCTFail("Expected the active relay check to fail")
        } catch let error as AudioOutputIsolationError {
            XCTAssertEqual(error, .activeOutputProcessSetMismatch(
                stage: "after first DefaultOutput render",
                expected: [135],
                actual: [135, 777]
            ))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(events.values.contains("tone.stop"))
        XCTAssertTrue(events.values.contains("tone.destroy"))
        XCTAssertTrue(events.values.contains("tap.destroy"))
    }

    private func makeController(
        events: IsolationEventRecorder,
        delays: IsolationDelayRecorder = IsolationDelayRecorder(),
        tapController: IsolationTapStub? = nil,
        operations: IsolationOperationsStub? = nil
    ) -> AudioOutputIsolationTestController {
        AudioOutputIsolationTestController(
            outputDiscovery: IsolationOutputStub(events: events),
            tapController: tapController ?? IsolationTapStub(events: events),
            aggregateController: IsolationAggregateStub(events: events),
            operations: operations ?? IsolationOperationsStub(events: events),
            debugLogger: NullAudioDebugLogger(),
            evidenceRecorder: NullAudioOutputIsolationEvidenceRecorder(),
            phaseDelay: { delays.append($0) },
            challengeSeedProvider: { 0x1234_5678_9ABC_DEF0 }
        )
    }
}

private final class IsolationEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String] = []
    var values: [String] { lock.withLock { storedValues } }
    func append(_ value: String) { lock.withLock { storedValues.append(value) } }
}

private final class IsolationDelayRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Duration] = []
    var values: [Duration] { lock.withLock { storedValues } }
    func append(_ value: Duration) { lock.withLock { storedValues.append(value) } }
}

private struct IsolationOutputStub: DefaultOutputDeviceDiscovering {
    let events: IsolationEventRecorder
    func snapshot(generation: AudioGeneration) async -> AudioDeviceSnapshot {
        events.append("output")
        return AudioDeviceSnapshot(
            generation: generation,
            objectID: 94,
            uid: "BuiltInSpeakerDevice",
            name: "Built-in Speakers",
            isAlive: true,
            nominalSampleRate: 48_000,
            outputChannelCount: 2,
            outputLayout: AudioBufferLayout(buffers: [.init(index: 0, channelCount: 2)]),
            bufferFrameSize: 512,
            bufferFrameSizeRange: 32...4_096
        )
    }
}

private actor IsolationTapStub: ProcessTapControlling {
    let events: IsolationEventRecorder
    private var translatedIDs: [AudioObjectID]
    private var outputStates: [CoreAudioProcessOutputState]
    private var activeOutputSets: [[AudioObjectID]]

    init(
        events: IsolationEventRecorder,
        translatedIDs: [AudioObjectID] = [135, 135, 135],
        outputStates: [CoreAudioProcessOutputState] = [CoreAudioProcessOutputState(
            processObjectID: 135,
            isRunningOutput: true,
            outputDeviceIDs: [94]
        )],
        activeOutputSets: [[AudioObjectID]] = [[], [135], [135]]
    ) {
        self.events = events
        self.translatedIDs = translatedIDs
        self.outputStates = outputStates
        self.activeOutputSets = activeOutputSets
    }

    func currentProcessObjectID() async -> AudioObjectID {
        events.append("tap.identity")
        return translatedIDs.isEmpty ? 135 : translatedIDs.removeFirst()
    }

    func outputState(processObjectID: AudioObjectID) async -> CoreAudioProcessOutputState {
        events.append("tap.outputState")
        return outputStates.isEmpty
            ? CoreAudioProcessOutputState(
                processObjectID: processObjectID,
                isRunningOutput: true,
                outputDeviceIDs: [94]
            )
            : outputStates.removeFirst()
    }

    func activeOutputProcessObjectIDs(deviceID: AudioObjectID) async -> [AudioObjectID] {
        events.append("tap.activeOutputs")
        return activeOutputSets.isEmpty ? [135] : activeOutputSets.removeFirst()
    }

    func create(configuration: ProcessTapConfiguration) async -> ProcessTapResource {
        XCTAssertEqual(configuration.muteBehavior, .muted)
        XCTAssertEqual(configuration.outputDeviceUID, "BuiltInSpeakerDevice")
        XCTAssertNil(configuration.includedProcessObjectIDs)
        events.append("tap.create")
        return ProcessTapResource(
            descriptor: AudioResourceDescriptor(
                generation: configuration.generation,
                kind: .processTap,
                objectID: 700,
                persistentUID: "isolation.tap"
            ),
            selfProcessObjectID: 135,
            format: floatFormat(sampleRate: 48_000),
            muteBehavior: configuration.muteBehavior
        )
    }

    func destroy(_ resource: ProcessTapResource) async { events.append("tap.destroy") }

    func cleanupPendingCreation() async {}
}

private actor IsolationAggregateStub: AggregateDeviceControlling {
    let events: IsolationEventRecorder
    init(events: IsolationEventRecorder) { self.events = events }

    func create(
        configuration: AggregateDeviceConfiguration,
        output: AudioDeviceSnapshot,
        tap: ProcessTapResource
    ) async -> AggregateDeviceResource {
        events.append("aggregate.create")
        return AggregateDeviceResource(
            descriptor: AudioResourceDescriptor(
                generation: configuration.generation,
                kind: .aggregateDevice,
                objectID: 800,
                persistentUID: configuration.uid
            ),
            outputDeviceUID: output.uid,
            tapUID: tap.uid,
            tapUIDs: [tap.uid],
            inputLayout: AudioBufferLayout(buffers: [.init(index: 0, channelCount: 2)]),
            inputFormat: floatFormat(sampleRate: 48_000),
            nominalSampleRate: 48_000,
            maximumFrames: 4_096
        )
    }

    func destroy(_ resource: AggregateDeviceResource) async { events.append("aggregate.destroy") }

    func cleanupPendingCreation() async {}
}

private final class IsolationOperationsStub: AudioOutputIsolationOperations, @unchecked Sendable {
    private let events: IsolationEventRecorder
    private let startStatus: OSStatus
    private let drainFaultFlags: UInt32
    private let lock = NSLock()
    private var stopToneStatuses: [OSStatus]
    private var stopDrainStatuses: [OSStatus]
    private var challengeSamples: [Float] = []
    private var signalSequence: UInt64 = 0
    private var outputUnitCount: UInt64
    private let tone = OpaquePointer(bitPattern: 0x6000)!
    private let drain = OpaquePointer(bitPattern: 0x7000)!

    init(
        events: IsolationEventRecorder,
        startStatus: OSStatus = noErr,
        stopToneStatuses: [OSStatus] = [],
        stopDrainStatuses: [OSStatus] = [],
        drainFaultFlags: UInt32 = 0,
        initialOutputUnitCount: UInt64 = 0
    ) {
        self.events = events
        self.startStatus = startStatus
        self.stopToneStatuses = stopToneStatuses
        self.stopDrainStatuses = stopDrainStatuses
        self.drainFaultFlags = drainFaultFlags
        self.outputUnitCount = initialOutputUnitCount
    }

    func outputUnitCreationCount() -> UInt64 {
        events.append("output.count")
        return lock.withLock { outputUnitCount }
    }

    func createSignal(
        deviceID: AudioObjectID,
        sampleRate: Double,
        channelCount: UInt32,
        maximumFrames: UInt32,
        monoSamples: [Float],
        output: inout OpaquePointer?
    ) -> OSStatus {
        events.append("signal.create")
        XCTAssertEqual(deviceID, 94)
        XCTAssertEqual(sampleRate, 48_000)
        XCTAssertEqual(channelCount, 2)
        XCTAssertEqual(maximumFrames, 4_096)
        XCTAssertEqual(monoSamples.count, 48_000)
        lock.withLock {
            challengeSamples = monoSamples
            outputUnitCount += 1
        }
        output = tone
        return noErr
    }

    func startTone(_ output: OpaquePointer) -> OSStatus {
        events.append("tone.start")
        return startStatus
    }

    func stopTone(_ output: OpaquePointer) -> OSStatus {
        events.append("tone.stop")
        return lock.withLock {
            stopToneStatuses.isEmpty ? noErr : stopToneStatuses.removeFirst()
        }
    }

    func toneIsQuiescent(_ output: OpaquePointer) -> Bool { true }

    func toneSnapshot(_ output: OpaquePointer) -> AudioOutputIsolationToneSnapshot {
        AudioOutputIsolationToneSnapshot(
            callbackCount: 94,
            renderedFrames: 48_000,
            nonZeroSampleCount: 95_000,
            lastHostTime: 500,
            maxObservedFrames: 512,
            faultFlags: 0,
            silenceBlocks: 1,
            nonSilenceBlocks: 93,
            completed: true
        )
    }

    func toneDiagnostics(
        _ output: OpaquePointer
    ) -> (status: OSStatus, diagnostics: AudioOutputIsolationToneDiagnostics) {
        events.append("tone.diagnostics")
        return (
            noErr,
            AudioOutputIsolationToneDiagnostics(
                componentSubType: kAudioUnitSubType_DefaultOutput,
                currentDevice: 94,
                deviceFormat: AudioStreamBasicDescription(),
                clientFormat: floatFormat(sampleRate: 48_000),
                maximumFrames: 4_096
            )
        )
    }

    func destroyTone(_ output: OpaquePointer) -> OSStatus {
        events.append("tone.destroy")
        return noErr
    }

    func createDrain(
        deviceID: AudioObjectID,
        channelCount: UInt32,
        maximumFrames: UInt32,
        signalCaptureFrameCapacity: UInt32,
        registration: inout OpaquePointer?
    ) -> OSStatus {
        events.append("drain.create")
        XCTAssertEqual(deviceID, 800)
        XCTAssertEqual(channelCount, 2)
        XCTAssertEqual(maximumFrames, 4_096)
        XCTAssertEqual(signalCaptureFrameCapacity, 72_000)
        registration = drain
        return noErr
    }

    func startDrain(_ registration: OpaquePointer) -> OSStatus {
        events.append("drain.start")
        return noErr
    }

    func stopDrain(_ registration: OpaquePointer) -> OSStatus {
        events.append("drain.stop")
        return lock.withLock {
            stopDrainStatuses.isEmpty ? noErr : stopDrainStatuses.removeFirst()
        }
    }

    func drainIsQuiescent(_ registration: OpaquePointer) -> Bool { true }

    func drainSnapshot(_ registration: OpaquePointer) -> AudioOutputIsolationDrainSnapshot {
        AudioOutputIsolationDrainSnapshot(
            callbackCount: 120,
            capturedFrames: 60_000,
            nonZeroSampleCount: 95_000,
            lastHostTime: 600,
            maxObservedFrames: 512,
            faultFlags: drainFaultFlags
        )
    }

    func beginSignalCapture(_ registration: OpaquePointer) -> OSStatus {
        events.append("signal.begin")
        lock.withLock { signalSequence += 1 }
        return noErr
    }

    func endSignalCapture(_ registration: OpaquePointer) -> OSStatus {
        events.append("signal.end")
        return noErr
    }

    func signalCaptureIsQuiescent(_ registration: OpaquePointer) -> Bool { true }

    func signalCaptureWindow(
        _ registration: OpaquePointer,
        phase: AudioOutputIsolationSignalPhase,
        sampleRate: Double
    ) -> AudioOutputIsolationSignalWindow? {
        events.append("signal.window.\(phase.rawValue)")
        let reference = lock.withLock { challengeSamples }
        let offset = 512
        let frames = reference.count + 2 * offset
        var samples = [Float](repeating: 0, count: frames * 2)
        for (frame, sample) in reference.enumerated() {
            samples[(offset + frame) * 2] = sample * 0.8
            samples[(offset + frame) * 2 + 1] = sample * 0.8
        }
        return AudioOutputIsolationSignalWindow(
            phase: phase,
            sequence: lock.withLock { signalSequence },
            firstHostTime: 100,
            droppedFrames: 0,
            frameCount: UInt32(frames),
            channelCount: 2,
            sampleRate: sampleRate,
            samples: samples
        )
    }

    func destroyDrain(_ registration: OpaquePointer) -> OSStatus {
        events.append("drain.destroy")
        return noErr
    }
}

private func floatFormat(sampleRate: Double) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
        mBytesPerPacket: 8,
        mFramesPerPacket: 1,
        mBytesPerFrame: 8,
        mChannelsPerFrame: 2,
        mBitsPerChannel: 32,
        mReserved: 0
    )
}
