import Foundation

enum M1RetirementMaintenanceStep: Equatable, Sendable {
    case waiting
    case completed
    case maintenanceRequired(ticket: UInt64)
    case bridgeGenerationChanged
    case failed(status: Int32)
}

enum M1RetirementStopReason: Equatable, Sendable {
    case ticketTimedOut(ticket: UInt64)
    case maintenanceFailed(ticket: UInt64, status: Int32)
}

protocol M1RetirementMaintenanceAccess: Sendable {
    /// The implementation must validate the generation and retain the Runtime
    /// on one serialized executor before dereferencing the handle.
    func performMaintenance(
        ticket: UInt64,
        bridgeGeneration: UInt64
    ) async -> M1RetirementMaintenanceStep

    func discardPendingPrepared(bridgeGeneration: UInt64) async

    func requestRecoverableStop(
        reason: M1RetirementStopReason,
        bridgeGeneration: UInt64
    ) async
}

struct M1RetirementMaintenanceTiming: Sendable {
    static let pollIntervalNanoseconds: UInt64 = 1_000_000
    static let ticketDeadlineNanoseconds: UInt64 = 100_000_000

    let pollInterval: UInt64
    let ticketDeadline: UInt64
    let nowNanoseconds: @Sendable () async -> UInt64
    let sleep: @Sendable (_ nanoseconds: UInt64) async throws -> Void

    init(
        pollInterval: UInt64 = pollIntervalNanoseconds,
        ticketDeadline: UInt64 = ticketDeadlineNanoseconds,
        nowNanoseconds: @escaping @Sendable () async -> UInt64,
        sleep: @escaping @Sendable (_ nanoseconds: UInt64) async throws -> Void
    ) {
        precondition(pollInterval > 0)
        precondition(ticketDeadline >= pollInterval)
        self.pollInterval = pollInterval
        self.ticketDeadline = ticketDeadline
        self.nowNanoseconds = nowNanoseconds
        self.sleep = sleep
    }
}

actor M1RetirementMaintenanceCoordinator {
    private let access: any M1RetirementMaintenanceAccess
    private let timing: M1RetirementMaintenanceTiming
    private var maintenanceTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var stopJoinerCount = 0
    private var activeBridgeGeneration: UInt64?
    private var runIdentifier: UInt64 = 0
    private var isStopping = false

    init(
        access: any M1RetirementMaintenanceAccess,
        timing: M1RetirementMaintenanceTiming
    ) {
        self.access = access
        self.timing = timing
    }

    @discardableResult
    func start(ticket: UInt64, bridgeGeneration: UInt64) -> Bool {
        guard maintenanceTask == nil, !isStopping else {
            return false
        }

        runIdentifier &+= 1
        let identifier = runIdentifier
        activeBridgeGeneration = bridgeGeneration
        maintenanceTask = Task { [access, timing] in
            let stopReason = await Self.runMaintenanceLoop(
                initialTicket: ticket,
                bridgeGeneration: bridgeGeneration,
                access: access,
                timing: timing
            )
            guard await self.finishRun(identifier: identifier) else { return }
            if let stopReason {
                await access.requestRecoverableStop(
                    reason: stopReason,
                    bridgeGeneration: bridgeGeneration
                )
            }
        }
        return true
    }

    func waitUntilIdle() async {
        let task = maintenanceTask
        await task?.value
    }

    /// Stop cancels and joins maintenance before handing pending-candidate
    /// disposal to the same generation-checked serialized access boundary.
    /// Calls for an older generation do not affect the current run.
    @discardableResult
    func stop(bridgeGeneration: UInt64) async -> Bool {
        guard activeBridgeGeneration == bridgeGeneration else {
            return false
        }
        if let stopTask {
            stopJoinerCount += 1
            await stopTask.value
            stopJoinerCount -= 1
            return true
        }

        isStopping = true
        runIdentifier &+= 1
        let taskToJoin = maintenanceTask
        let cleanupTask = Task { [access] in
            taskToJoin?.cancel()
            await taskToJoin?.value
            await access.discardPendingPrepared(bridgeGeneration: bridgeGeneration)
        }
        stopTask = cleanupTask
        await cleanupTask.value
        maintenanceTask = nil
        stopTask = nil
        activeBridgeGeneration = nil
        isStopping = false
        return true
    }

    func stopJoinerCountForTesting() -> Int {
        stopJoinerCount
    }

    private func finishRun(identifier: UInt64) -> Bool {
        guard identifier == runIdentifier else {
            return false
        }
        maintenanceTask = nil
        return true
    }

    private static func runMaintenanceLoop(
        initialTicket: UInt64,
        bridgeGeneration: UInt64,
        access: any M1RetirementMaintenanceAccess,
        timing: M1RetirementMaintenanceTiming
    ) async -> M1RetirementStopReason? {
        var ticket = initialTicket
        var ticketStartedAt = await timing.nowNanoseconds()

        while !Task.isCancelled {
            do {
                try await timing.sleep(timing.pollInterval)
            } catch {
                return nil
            }
            guard !Task.isCancelled else {
                return nil
            }

            let step = await access.performMaintenance(
                ticket: ticket,
                bridgeGeneration: bridgeGeneration
            )
            guard !Task.isCancelled else {
                return nil
            }
            switch step {
            case .waiting:
                let now = await timing.nowNanoseconds()
                guard !Task.isCancelled else {
                    return nil
                }
                let elapsed = now >= ticketStartedAt
                    ? now - ticketStartedAt
                    : UInt64.max
                if elapsed >= timing.ticketDeadline {
                    return .ticketTimedOut(ticket: ticket)
                }

            case .completed, .bridgeGenerationChanged:
                return nil

            case let .maintenanceRequired(newTicket):
                if newTicket != ticket {
                    ticket = newTicket
                    ticketStartedAt = await timing.nowNanoseconds()
                }

            case let .failed(status):
                return .maintenanceFailed(ticket: ticket, status: status)
            }
        }
        return nil
    }
}
