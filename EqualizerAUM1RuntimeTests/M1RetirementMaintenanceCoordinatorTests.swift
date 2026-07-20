import XCTest

final class M1RetirementMaintenanceCoordinatorTests: XCTestCase {
    func testMaintenanceProgressesWithoutAnotherUserCommand() async {
        let clock = TestMonotonicClock()
        let access = TestMaintenanceAccess(steps: [.waiting, .completed])
        let coordinator = M1RetirementMaintenanceCoordinator(
            access: access,
            timing: clock.timing()
        )

        let started = await coordinator.start(ticket: 7, bridgeGeneration: 3)
        XCTAssertTrue(started)
        await coordinator.waitUntilIdle()

        let calls = await access.maintenanceCalls()
        let sleeps = await clock.sleepDurations()
        let stopRequests = await access.stopRequests()
        XCTAssertEqual(calls, [
            .init(ticket: 7, generation: 3),
            .init(ticket: 7, generation: 3),
        ])
        XCTAssertEqual(sleeps, [1_000_000, 1_000_000])
        XCTAssertTrue(stopRequests.isEmpty)
    }

    func testNewTicketStartsItsOwnDeadline() async {
        let clock = TestMonotonicClock()
        let access = TestMaintenanceAccess(steps: [
            .maintenanceRequired(ticket: 8),
            .waiting,
            .waiting,
            .completed,
        ])
        let coordinator = M1RetirementMaintenanceCoordinator(
            access: access,
            timing: clock.timing(pollInterval: 10, ticketDeadline: 30)
        )

        let started = await coordinator.start(ticket: 7, bridgeGeneration: 4)
        XCTAssertTrue(started)
        await coordinator.waitUntilIdle()

        let tickets = await access.maintenanceCalls().map(\.ticket)
        let stopRequests = await access.stopRequests()
        let currentTime = await clock.currentTime()
        XCTAssertEqual(tickets, [7, 8, 8, 8])
        XCTAssertTrue(stopRequests.isEmpty)
        XCTAssertEqual(currentTime, 40)
    }

    func testExactTicketDeadlineRequestsRecoverableStopWithoutReclaiming() async {
        let clock = TestMonotonicClock()
        let access = TestMaintenanceAccess(steps: [])
        let coordinator = M1RetirementMaintenanceCoordinator(
            access: access,
            timing: clock.timing(pollInterval: 1, ticketDeadline: 3)
        )

        let started = await coordinator.start(ticket: 11, bridgeGeneration: 5)
        XCTAssertTrue(started)
        await coordinator.waitUntilIdle()

        let callCount = await access.maintenanceCalls().count
        let stopRequests = await access.stopRequests()
        let discards = await access.discardGenerations()
        XCTAssertEqual(callCount, 3)
        XCTAssertEqual(stopRequests, [
            .init(reason: .ticketTimedOut(ticket: 11), generation: 5),
        ])
        XCTAssertTrue(discards.isEmpty)
    }

    func testGenerationChangeStopsBeforeAnotherRuntimeAccess() async {
        let clock = TestMonotonicClock()
        let access = TestMaintenanceAccess(steps: [.bridgeGenerationChanged])
        let coordinator = M1RetirementMaintenanceCoordinator(
            access: access,
            timing: clock.timing()
        )

        let started = await coordinator.start(ticket: 13, bridgeGeneration: 6)
        XCTAssertTrue(started)
        await coordinator.waitUntilIdle()

        let callCount = await access.maintenanceCalls().count
        let stopRequests = await access.stopRequests()
        XCTAssertEqual(callCount, 1)
        XCTAssertTrue(stopRequests.isEmpty)
    }

    func testMaintenanceFailureRequestsRecoverableStop() async {
        let clock = TestMonotonicClock()
        let access = TestMaintenanceAccess(steps: [.failed(status: 7)])
        let coordinator = M1RetirementMaintenanceCoordinator(
            access: access,
            timing: clock.timing()
        )

        let started = await coordinator.start(ticket: 17, bridgeGeneration: 9)
        XCTAssertTrue(started)
        await coordinator.waitUntilIdle()

        let stopRequests = await access.stopRequests()
        XCTAssertEqual(stopRequests, [
            .init(reason: .maintenanceFailed(ticket: 17, status: 7), generation: 9),
        ])
    }

    func testStopCancelsAndJoinsBeforeDiscardingPendingCandidate() async {
        let gate = TestSleepGate()
        let access = TestMaintenanceAccess(steps: [])
        let timing = M1RetirementMaintenanceTiming(
            nowNanoseconds: { 0 },
            sleep: { _ in
                await gate.markEntered()
                try await Task<Never, Never>.sleep(nanoseconds: 60_000_000_000)
            }
        )
        let coordinator = M1RetirementMaintenanceCoordinator(
            access: access,
            timing: timing
        )

        let started = await coordinator.start(ticket: 19, bridgeGeneration: 12)
        XCTAssertTrue(started)
        await gate.waitUntilEntered()
        let duplicateStarted = await coordinator.start(ticket: 20, bridgeGeneration: 12)
        XCTAssertFalse(duplicateStarted)
        await coordinator.stop(bridgeGeneration: 12)

        let calls = await access.maintenanceCalls()
        let discards = await access.discardGenerations()
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(discards, [12])
    }

    func testStopBlocksRestartAndIgnoresMaintenanceResultAfterCancellation() async {
        let enteredGate = TestSleepGate()
        let cancellationGate = TestSleepGate()
        let releaseGate = TestSleepGate()
        let access = BlockingMaintenanceAccess(
            enteredGate: enteredGate,
            cancellationGate: cancellationGate,
            releaseGate: releaseGate
        )
        let clock = TestMonotonicClock()
        let coordinator = M1RetirementMaintenanceCoordinator(
            access: access,
            timing: clock.timing()
        )

        let started = await coordinator.start(ticket: 23, bridgeGeneration: 14)
        XCTAssertTrue(started)
        await enteredGate.waitUntilEntered()

        let stopTask = Task {
            await coordinator.stop(bridgeGeneration: 14)
        }
        await cancellationGate.waitUntilEntered()
        let restarted = await coordinator.start(ticket: 24, bridgeGeneration: 14)
        XCTAssertFalse(restarted)

        await releaseGate.markEntered()
        await stopTask.value

        let stopRequests = await access.stopRequests()
        let discards = await access.discardGenerations()
        XCTAssertTrue(stopRequests.isEmpty)
        XCTAssertEqual(discards, [14])
    }

    func testConcurrentStopCallsJoinTheSameCleanup() async {
        let enteredGate = TestSleepGate()
        let cancellationGate = TestSleepGate()
        let releaseGate = TestSleepGate()
        let access = BlockingMaintenanceAccess(
            enteredGate: enteredGate,
            cancellationGate: cancellationGate,
            releaseGate: releaseGate
        )
        let coordinator = M1RetirementMaintenanceCoordinator(
            access: access,
            timing: TestMonotonicClock().timing()
        )

        let started = await coordinator.start(ticket: 29, bridgeGeneration: 18)
        XCTAssertTrue(started)
        await enteredGate.waitUntilEntered()

        let firstStop = Task {
            await coordinator.stop(bridgeGeneration: 18)
        }
        await cancellationGate.waitUntilEntered()
        let secondStop = Task {
            await coordinator.stop(bridgeGeneration: 18)
        }

        var observedJoiner = false
        for _ in 0..<1_000 {
            if await coordinator.stopJoinerCountForTesting() == 1 {
                observedJoiner = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(observedJoiner)

        await releaseGate.markEntered()
        await firstStop.value
        await secondStop.value

        let discards = await access.discardGenerations()
        let stopRequests = await access.stopRequests()
        XCTAssertEqual(discards, [18])
        XCTAssertTrue(stopRequests.isEmpty)
    }

    func testStaleGenerationStopDoesNotCancelCurrentMaintenance() async {
        let enteredGate = TestSleepGate()
        let cancellationGate = TestSleepGate()
        let releaseGate = TestSleepGate()
        let access = BlockingMaintenanceAccess(
            enteredGate: enteredGate,
            cancellationGate: cancellationGate,
            releaseGate: releaseGate
        )
        let coordinator = M1RetirementMaintenanceCoordinator(
            access: access,
            timing: TestMonotonicClock().timing()
        )

        let started = await coordinator.start(ticket: 31, bridgeGeneration: 20)
        XCTAssertTrue(started)
        await enteredGate.waitUntilEntered()

        let staleStopAccepted = await coordinator.stop(bridgeGeneration: 19)
        let cancellationObserved = await cancellationGate.isEntered()
        let discardsBeforeCurrentStop = await access.discardGenerations()
        XCTAssertFalse(staleStopAccepted)
        XCTAssertFalse(cancellationObserved)
        XCTAssertTrue(discardsBeforeCurrentStop.isEmpty)

        let currentStop = Task {
            await coordinator.stop(bridgeGeneration: 20)
        }
        await cancellationGate.waitUntilEntered()
        await releaseGate.markEntered()
        let currentStopAccepted = await currentStop.value

        let discards = await access.discardGenerations()
        XCTAssertTrue(currentStopAccepted)
        XCTAssertEqual(discards, [20])
    }

    func testRecoverableStopCanSynchronouslyStopCoordinatorWithoutSelfJoin() async {
        let access = ReentrantStopMaintenanceAccess()
        let coordinator = M1RetirementMaintenanceCoordinator(
            access: access,
            timing: TestMonotonicClock().timing()
        )
        let stopReturned = expectation(description: "recoverable stop returned")
        await access.setStopHandler { _, generation in
            _ = await coordinator.stop(bridgeGeneration: generation)
            stopReturned.fulfill()
        }

        let started = await coordinator.start(ticket: 37, bridgeGeneration: 22)
        XCTAssertTrue(started)
        await fulfillment(of: [stopReturned], timeout: 1)

        let discards = await access.discardGenerations()
        XCTAssertEqual(discards, [22])
    }
}

private struct TestMaintenanceCall: Equatable, Sendable {
    let ticket: UInt64
    let generation: UInt64
}

private struct TestStopRequest: Equatable, Sendable {
    let reason: M1RetirementStopReason
    let generation: UInt64
}

private actor TestMaintenanceAccess: M1RetirementMaintenanceAccess {
    private var steps: [M1RetirementMaintenanceStep]
    private var calls: [TestMaintenanceCall] = []
    private var discards: [UInt64] = []
    private var requests: [TestStopRequest] = []

    init(steps: [M1RetirementMaintenanceStep]) {
        self.steps = steps
    }

    func performMaintenance(
        ticket: UInt64,
        bridgeGeneration: UInt64
    ) -> M1RetirementMaintenanceStep {
        calls.append(.init(ticket: ticket, generation: bridgeGeneration))
        return steps.isEmpty ? .waiting : steps.removeFirst()
    }

    func discardPendingPrepared(bridgeGeneration: UInt64) {
        discards.append(bridgeGeneration)
    }

    func requestRecoverableStop(
        reason: M1RetirementStopReason,
        bridgeGeneration: UInt64
    ) {
        requests.append(.init(reason: reason, generation: bridgeGeneration))
    }

    func maintenanceCalls() -> [TestMaintenanceCall] {
        calls
    }

    func discardGenerations() -> [UInt64] {
        discards
    }

    func stopRequests() -> [TestStopRequest] {
        requests
    }
}

private actor TestMonotonicClock {
    private var now: UInt64 = 0
    private var sleeps: [UInt64] = []

    nonisolated func timing(
        pollInterval: UInt64 = M1RetirementMaintenanceTiming.pollIntervalNanoseconds,
        ticketDeadline: UInt64 = M1RetirementMaintenanceTiming.ticketDeadlineNanoseconds
    ) -> M1RetirementMaintenanceTiming {
        M1RetirementMaintenanceTiming(
            pollInterval: pollInterval,
            ticketDeadline: ticketDeadline,
            nowNanoseconds: { await self.currentTime() },
            sleep: { duration in try await self.advance(by: duration) }
        )
    }

    func currentTime() -> UInt64 {
        now
    }

    func sleepDurations() -> [UInt64] {
        sleeps
    }

    private func advance(by duration: UInt64) throws {
        try Task.checkCancellation()
        sleeps.append(duration)
        now &+= duration
        try Task.checkCancellation()
    }
}

private actor BlockingMaintenanceAccess: M1RetirementMaintenanceAccess {
    private let enteredGate: TestSleepGate
    private let cancellationGate: TestSleepGate
    private let releaseGate: TestSleepGate
    private var discards: [UInt64] = []
    private var requests: [TestStopRequest] = []

    init(
        enteredGate: TestSleepGate,
        cancellationGate: TestSleepGate,
        releaseGate: TestSleepGate
    ) {
        self.enteredGate = enteredGate
        self.cancellationGate = cancellationGate
        self.releaseGate = releaseGate
    }

    func performMaintenance(
        ticket: UInt64,
        bridgeGeneration: UInt64
    ) async -> M1RetirementMaintenanceStep {
        await enteredGate.markEntered()
        return await withTaskCancellationHandler {
            await releaseGate.waitUntilEntered()
            return .failed(status: 99)
        } onCancel: {
            Task {
                await self.cancellationGate.markEntered()
            }
        }
    }

    func discardPendingPrepared(bridgeGeneration: UInt64) {
        discards.append(bridgeGeneration)
    }

    func requestRecoverableStop(
        reason: M1RetirementStopReason,
        bridgeGeneration: UInt64
    ) {
        requests.append(.init(reason: reason, generation: bridgeGeneration))
    }

    func discardGenerations() -> [UInt64] {
        discards
    }

    func stopRequests() -> [TestStopRequest] {
        requests
    }
}

private actor ReentrantStopMaintenanceAccess: M1RetirementMaintenanceAccess {
    typealias StopHandler = @Sendable (M1RetirementStopReason, UInt64) async -> Void

    private var stopHandler: StopHandler?
    private var discards: [UInt64] = []

    func setStopHandler(_ handler: @escaping StopHandler) {
        stopHandler = handler
    }

    func performMaintenance(
        ticket: UInt64,
        bridgeGeneration: UInt64
    ) -> M1RetirementMaintenanceStep {
        .failed(status: 99)
    }

    func discardPendingPrepared(bridgeGeneration: UInt64) {
        discards.append(bridgeGeneration)
    }

    func requestRecoverableStop(
        reason: M1RetirementStopReason,
        bridgeGeneration: UInt64
    ) async {
        await stopHandler?(reason, bridgeGeneration)
    }

    func discardGenerations() -> [UInt64] {
        discards
    }
}

private actor TestSleepGate {
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markEntered() {
        entered = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitUntilEntered() async {
        if entered {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func isEntered() -> Bool {
        entered
    }
}
