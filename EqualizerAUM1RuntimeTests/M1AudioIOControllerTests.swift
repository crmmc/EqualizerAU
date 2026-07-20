import Foundation
import XCTest

final class M1AudioIOControllerTests: XCTestCase {
    func testDiagnosticsPropagateHostCountersForOwnedResource() async throws {
        let operations = TestAudioIOOperations()
        let controller = M1AudioIOController(operations: operations, timing: testTiming())
        let fixture = try await makeIOResource(controller: controller)

        let counters = try await controller.diagnostics(fixture.resource)

        XCTAssertEqual(counters, M1AudioIOHostCounters(
            capturedFrames: 1,
            renderedFrames: 2,
            overflowedBlocks: 3,
            underrunBlocks: 4,
            droppedBacklogFrames: 5,
            invalidCallbacks: 6,
            overlappingRenderCallbacks: 7
        ))
        XCTAssertEqual(operations.calls.last, "hostDiagnostics")
    }

    func testCaptureMustStartBeforeOutputAndStopOrderIsOutputFirst() async throws {
        let operations = TestAudioIOOperations()
        let controller = M1AudioIOController(operations: operations, timing: testTiming())
        let fixture = try await makeIOResource(controller: controller)

        do {
            try await controller.createOutput(fixture.resource)
            XCTFail("output creation must require running capture")
        } catch let error as M1AudioIOError {
            XCTAssertEqual(error, .invalidState("capture must be running before output creation"))
        }

        try await controller.startCapture(fixture.resource)
        try await controller.createOutput(fixture.resource)
        try await controller.startOutput(fixture.resource)
        try await controller.stop(fixture.resource)
        XCTAssertEqual(operations.calls, [
            "createHost", "createCapture", "startCapture", "createOutput",
            "outputDiagnostics", "startOutput", "outputDiagnostics",
            "fade", "stopOutput", "stopCapture", "beginStopping",
        ])
    }

    func testOutputStopFailureDoesNotStopCaptureOrCloseAdmission() async throws {
        let operations = TestAudioIOOperations()
        operations.stopOutputFailuresRemaining = 1
        let controller = M1AudioIOController(operations: operations, timing: testTiming())
        let fixture = try await makeRunningIOResource(controller: controller)

        do {
            try await controller.stop(fixture.resource)
            XCTFail("injected output stop failure must surface")
        } catch TestAudioIOFailure.injected {}
        XCTAssertFalse(operations.calls.contains("stopCapture"))
        XCTAssertFalse(operations.calls.contains("beginStopping"))

        try await controller.stop(fixture.resource)
        let stopCalls = operations.calls.filter {
            $0 == "stopOutput" || $0 == "stopCapture" || $0 == "beginStopping"
        }
        XCTAssertEqual(stopCalls, ["stopOutput", "stopOutput", "stopCapture", "beginStopping"])
    }

    func testStartedOutputReadbackFailureRetainsRunningStateWhenRollbackStopFails() async throws {
        let operations = TestAudioIOOperations()
        operations.runningDiagnosticsAreInvalid = true
        operations.stopOutputFailuresRemaining = 1
        let controller = M1AudioIOController(operations: operations, timing: testTiming())
        let fixture = try await makeIOResource(controller: controller)
        try await controller.startCapture(fixture.resource)
        try await controller.createOutput(fixture.resource)

        do {
            try await controller.startOutput(fixture.resource)
            XCTFail("invalid running diagnostics must fail")
        } catch TestAudioIOFailure.injected {}
        XCTAssertEqual(operations.calls.filter { $0 == "stopOutput" }.count, 1)

        operations.runningDiagnosticsAreInvalid = false
        try await controller.stop(fixture.resource)
        XCTAssertEqual(operations.calls.filter { $0 == "stopOutput" }.count, 2)
        XCTAssertTrue(operations.calls.contains("stopCapture"))
    }

    func testOutputValidationCleanupFailureRetainsHandleForDestroyRetry() async throws {
        let operations = TestAudioIOOperations()
        operations.creationDiagnosticsAreInvalid = true
        operations.destroyOutputFailuresRemaining = 1
        let controller = M1AudioIOController(operations: operations, timing: testTiming())
        let fixture = try await makeIOResource(controller: controller)
        try await controller.startCapture(fixture.resource)

        do {
            try await controller.createOutput(fixture.resource)
            XCTFail("invalid output diagnostics must fail")
        } catch TestAudioIOFailure.injected {}
        XCTAssertEqual(operations.calls.filter { $0 == "destroyOutput" }.count, 1)

        try await controller.stop(fixture.resource)
        try await controller.destroy(fixture.resource)
        XCTAssertEqual(operations.calls.filter { $0 == "destroyOutput" }.count, 2)
        XCTAssertEqual(
            Array(operations.calls.suffix(4)),
            ["destroyOutput", "destroyCapture", "isQuiescent", "destroyHost"]
        )
    }

    func testRetainedOutputCreationFailureIsOwnedUntilDestroy() async throws {
        let operations = TestAudioIOOperations()
        operations.createOutputReturnsRetainedFailure = true
        let controller = M1AudioIOController(operations: operations, timing: testTiming())
        let fixture = try await makeIOResource(controller: controller)
        try await controller.startCapture(fixture.resource)

        do {
            try await controller.createOutput(fixture.resource)
            XCTFail("retained creation failure must surface")
        } catch TestAudioIOFailure.injected {}
        try await controller.stop(fixture.resource)
        try await controller.destroy(fixture.resource)
        XCTAssertEqual(operations.calls.filter { $0 == "destroyOutput" }.count, 1)
    }

    func testDestroyTimeoutRetainsAllHandlesForRetry() async throws {
        let operations = TestAudioIOOperations()
        operations.quiescent = false
        let clock = TestAudioIOClock()
        let controller = M1AudioIOController(
            operations: operations,
            timing: clock.timing(pollInterval: 1, quiescenceDeadline: 3)
        )
        let fixture = try await makeIOResource(controller: controller)
        try await controller.startCapture(fixture.resource)
        try await controller.createOutput(fixture.resource)
        try await controller.stop(fixture.resource)

        do {
            try await controller.destroy(fixture.resource)
            XCTFail("non-quiescent callbacks must retain resources")
        } catch let error as M1AudioIOError {
            XCTAssertEqual(error, .callbacksDidNotQuiesce)
        }
        XCTAssertTrue(operations.calls.contains("destroyCapture"))
        XCTAssertFalse(operations.calls.contains("destroyHost"))
        let callsAfterTimeout = operations.calls
        let outputDestroyCount = callsAfterTimeout.filter { $0 == "destroyOutput" }.count
        let captureDestroyCount = callsAfterTimeout.filter { $0 == "destroyCapture" }.count
        let firstQuiescenceIndex = try XCTUnwrap(callsAfterTimeout.firstIndex(of: "isQuiescent"))
        XCTAssertLessThan(try XCTUnwrap(callsAfterTimeout.firstIndex(of: "destroyOutput")), firstQuiescenceIndex)
        XCTAssertLessThan(try XCTUnwrap(callsAfterTimeout.firstIndex(of: "destroyCapture")), firstQuiescenceIndex)

        operations.quiescent = true
        try await controller.destroy(fixture.resource)
        XCTAssertEqual(operations.calls.filter { $0 == "destroyOutput" }.count, outputDestroyCount)
        XCTAssertEqual(operations.calls.filter { $0 == "destroyCapture" }.count, captureDestroyCount)
        XCTAssertTrue(operations.calls.contains("destroyCapture"))
        XCTAssertTrue(operations.calls.contains("destroyHost"))
    }
}

private struct IOFixture {
    let resource: M1AudioIOResource
}

private func makeIOResource(controller: M1AudioIOController) async throws -> IOFixture {
    let generation = M1AudioRouteGeneration(rawValue: 1)
    let layout = M1OutputLayoutSnapshot(
        sampleRate: 48_000,
        maximumFrameCount: 128,
        bufferChannelCounts: [2],
        semanticPositionsByChannelIndex: [
            M1SpeakerPosition(rawValue: "L"),
            M1SpeakerPosition(rawValue: "R"),
        ]
    )!
    let output = M1OutputDeviceSnapshot(
        generation: generation,
        objectID: 42,
        uid: "device.uid",
        name: "Output",
        layout: layout
    )
    let format = M1HALPCMFormat(
        sampleRate: 48_000,
        channelCount: 2,
        isNativeFloat32: true,
        isPacked: true,
        isNonInterleaved: false,
        framesPerPacket: 1,
        bytesPerFrame: 8,
        bytesPerPacket: 8
    )
    let aggregate = M1AggregateResource(
        descriptor: M1HALResourceDescriptor(
            ownershipToken: UUID(),
            generation: generation,
            kind: .aggregateDevice,
            objectID: 202,
            persistentUID: "aggregate.uid"
        ),
        outputDeviceUID: output.uid,
        tapUID: "tap.uid",
        format: format,
        maximumFrameCount: 128,
        bufferChannelCounts: [2]
    )
    let runtime = M1RuntimeHandleLease(
        bridgeGeneration: 11,
        pointer: OpaquePointer(bitPattern: 0x1000)!
    )
    let resource = try await controller.create(
        generation: generation,
        bridgeGeneration: 11,
        aggregate: aggregate,
        output: output,
        runtime: runtime
    )
    return IOFixture(resource: resource)
}

private func makeRunningIOResource(controller: M1AudioIOController) async throws -> IOFixture {
    let fixture = try await makeIOResource(controller: controller)
    try await controller.startCapture(fixture.resource)
    try await controller.createOutput(fixture.resource)
    try await controller.startOutput(fixture.resource)
    return fixture
}

private func testTiming() -> M1AudioIOControlTiming {
    M1AudioIOControlTiming(
        nowNanoseconds: { 0 },
        sleep: { _ in }
    )
}

private final class TestAudioIOOperations: M1AudioIOOperations, @unchecked Sendable {
    var calls: [String] = []
    var stopOutputFailuresRemaining = 0
    var destroyOutputFailuresRemaining = 0
    var creationDiagnosticsAreInvalid = false
    var runningDiagnosticsAreInvalid = false
    var createOutputReturnsRetainedFailure = false
    var quiescent = true
    private var outputRunning = false

    func createHost(
        configuration: M1AudioIOHostConfiguration,
        runtime: M1RuntimeHandleLease
    ) throws -> M1AudioIOHostHandle {
        calls.append("createHost")
        return M1AudioIOHostHandle()
    }

    func beginStopping(_ host: M1AudioIOHostHandle) { calls.append("beginStopping") }
    func requestFadeOut(_ host: M1AudioIOHostHandle, frameCount: Int) { calls.append("fade") }
    func isFadeComplete(_ host: M1AudioIOHostHandle) -> Bool { true }
    func isQuiescent(_ host: M1AudioIOHostHandle) -> Bool {
        calls.append("isQuiescent")
        return quiescent
    }
    func hostDiagnostics(_ host: M1AudioIOHostHandle) throws -> M1AudioIOHostCounters {
        calls.append("hostDiagnostics")
        return M1AudioIOHostCounters(
            capturedFrames: 1,
            renderedFrames: 2,
            overflowedBlocks: 3,
            underrunBlocks: 4,
            droppedBacklogFrames: 5,
            invalidCallbacks: 6,
            overlappingRenderCallbacks: 7
        )
    }
    func destroyHost(_ host: M1AudioIOHostHandle) { calls.append("destroyHost") }

    func createCapture(
        aggregateDeviceID: UInt32,
        host: M1AudioIOHostHandle
    ) throws -> M1CaptureHandle {
        calls.append("createCapture")
        return M1CaptureHandle()
    }

    func startCapture(_ capture: M1CaptureHandle) throws { calls.append("startCapture") }
    func stopCapture(_ capture: M1CaptureHandle) throws { calls.append("stopCapture") }
    func destroyCapture(_ capture: M1CaptureHandle) throws { calls.append("destroyCapture") }

    func createOutput(
        deviceID: UInt32,
        sampleRate: Double,
        channelCount: Int,
        maximumFrameCount: Int,
        host: M1AudioIOHostHandle
    ) throws -> M1OutputHandle {
        calls.append("createOutput")
        let output = M1OutputHandle()
        if createOutputReturnsRetainedFailure {
            throw M1RetainedOutputCreationError(output: output, underlying: TestAudioIOFailure.injected)
        }
        return output
    }

    func startOutput(_ output: M1OutputHandle) throws {
        calls.append("startOutput")
        outputRunning = true
    }

    func stopOutput(_ output: M1OutputHandle) throws {
        calls.append("stopOutput")
        if stopOutputFailuresRemaining > 0 {
            stopOutputFailuresRemaining -= 1
            throw TestAudioIOFailure.injected
        }
        outputRunning = false
    }

    func outputDiagnostics(_ output: M1OutputHandle) throws -> M1OutputHostDiagnostics {
        calls.append("outputDiagnostics")
        if (outputRunning && runningDiagnosticsAreInvalid)
            || (!outputRunning && creationDiagnosticsAreInvalid) {
            throw TestAudioIOFailure.injected
        }
        return M1OutputHostDiagnostics(
            currentDeviceID: 42,
            currentDeviceUID: "device.uid",
            deviceSampleRate: 48_000,
            deviceChannelCount: 2,
            deviceFormatSupported: true,
            clientSampleRate: 48_000,
            clientChannelCount: 2,
            clientFormatSupported: true,
            maximumFrameCount: 128,
            isRunning: outputRunning
        )
    }

    func destroyOutput(_ output: M1OutputHandle) throws {
        calls.append("destroyOutput")
        if destroyOutputFailuresRemaining > 0 {
            destroyOutputFailuresRemaining -= 1
            throw TestAudioIOFailure.injected
        }
    }
}

private actor TestAudioIOClock {
    private var now: UInt64 = 0

    nonisolated func timing(
        pollInterval: UInt64,
        quiescenceDeadline: UInt64
    ) -> M1AudioIOControlTiming {
        M1AudioIOControlTiming(
            pollIntervalNanoseconds: pollInterval,
            fadeDeadlineNanoseconds: quiescenceDeadline,
            quiescenceDeadlineNanoseconds: quiescenceDeadline,
            nowNanoseconds: { await self.nowValue() },
            sleep: { duration in await self.advance(duration) }
        )
    }

    private func nowValue() -> UInt64 { now }
    private func advance(_ duration: UInt64) { now += duration }
}

private enum TestAudioIOFailure: Error {
    case injected
}
