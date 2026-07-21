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
    private var activeTicket: UInt64?
    private var pendingTicket: UInt64?
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
        guard !isStopping else {
            return false
        }
        if maintenanceTask != nil {
            guard activeBridgeGeneration == bridgeGeneration else { return false }
            if ticket != activeTicket {
                pendingTicket = ticket
            }
            return false
        }

        runIdentifier &+= 1
        let identifier = runIdentifier
        activeBridgeGeneration = bridgeGeneration
        activeTicket = ticket
        pendingTicket = nil
        maintenanceTask = Task {
            await self.runMaintenanceLoop(
                initialTicket: ticket,
                bridgeGeneration: bridgeGeneration,
                identifier: identifier
            )
        }
        return true
    }

    func waitUntilIdle() async {
        let task = maintenanceTask
        await task?.value
    }

    @discardableResult
    func discardPending(bridgeGeneration: UInt64) async -> Bool {
        guard activeBridgeGeneration == bridgeGeneration, !isStopping else {
            return false
        }
        await access.discardPendingPrepared(bridgeGeneration: bridgeGeneration)
        return true
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
        activeTicket = nil
        pendingTicket = nil
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
        activeTicket = nil
        pendingTicket = nil
        return true
    }

    private func runMaintenanceLoop(
        initialTicket: UInt64,
        bridgeGeneration: UInt64,
        identifier: UInt64
    ) async {
        var ticket = initialTicket
        var ticketStartedAt = await timing.nowNanoseconds()

        while !Task.isCancelled {
            do {
                try await timing.sleep(timing.pollInterval)
            } catch {
                _ = finishRun(identifier: identifier)
                return
            }
            guard !Task.isCancelled else {
                _ = finishRun(identifier: identifier)
                return
            }

            let step = await access.performMaintenance(
                ticket: ticket,
                bridgeGeneration: bridgeGeneration
            )
            guard !Task.isCancelled else {
                _ = finishRun(identifier: identifier)
                return
            }
            switch step {
            case .waiting:
                let now = await timing.nowNanoseconds()
                guard !Task.isCancelled else {
                    _ = finishRun(identifier: identifier)
                    return
                }
                let elapsed = now >= ticketStartedAt
                    ? now - ticketStartedAt
                    : UInt64.max
                if elapsed >= timing.ticketDeadline {
                    let reason = M1RetirementStopReason.ticketTimedOut(
                        ticket: ticket
                    )
                    guard finishRun(identifier: identifier) else { return }
                    await access.requestRecoverableStop(
                        reason: reason,
                        bridgeGeneration: bridgeGeneration
                    )
                    return
                }

            case .completed:
                if let nextTicket = pendingTicket, nextTicket != ticket {
                    pendingTicket = nil
                    activeTicket = nextTicket
                    ticket = nextTicket
                    ticketStartedAt = await timing.nowNanoseconds()
                } else {
                    _ = finishRun(identifier: identifier)
                    return
                }

            case .bridgeGenerationChanged:
                _ = finishRun(identifier: identifier)
                return

            case let .maintenanceRequired(newTicket):
                if newTicket != ticket {
                    ticket = newTicket
                    activeTicket = newTicket
                    if pendingTicket == newTicket {
                        pendingTicket = nil
                    }
                    ticketStartedAt = await timing.nowNanoseconds()
                }

            case let .failed(status):
                let reason = M1RetirementStopReason.maintenanceFailed(
                    ticket: ticket,
                    status: status
                )
                guard finishRun(identifier: identifier) else { return }
                await access.requestRecoverableStop(
                    reason: reason,
                    bridgeGeneration: bridgeGeneration
                )
                return
            }
        }
        _ = finishRun(identifier: identifier)
    }
}
