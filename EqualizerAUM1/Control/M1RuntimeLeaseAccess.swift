import Foundation

actor M1RuntimeLeaseAccess: M1RetirementMaintenanceAccess {
    typealias StopHandler = @Sendable (M1RetirementStopReason, UInt64) async -> Void

    private var lease: M1RuntimeHandleLease?
    private let stopHandler: StopHandler

    init(stopHandler: @escaping StopHandler) {
        self.stopHandler = stopHandler
    }

    func install(_ lease: M1RuntimeHandleLease) -> Bool {
        guard self.lease == nil else { return false }
        self.lease = lease
        return true
    }

    func invalidate(bridgeGeneration: UInt64) -> M1RuntimeHandleLease? {
        guard lease?.bridgeGeneration == bridgeGeneration else { return nil }
        defer { lease = nil }
        return lease
    }

    func performMaintenance(
        ticket: UInt64,
        bridgeGeneration: UInt64
    ) -> M1RetirementMaintenanceStep {
        guard let retained = lease, retained.bridgeGeneration == bridgeGeneration else {
            return .bridgeGenerationChanged
        }
        var outcome = EAUM1PublicationOutcome()
        let status = EAUM1RuntimePerformMaintenance(retained.pointer, ticket, &outcome)
        guard status == EAUM1StatusOK else {
            return .failed(status: status)
        }
        if outcome.flags & UInt32(EAUM1PublicationMaintenanceRequired) != 0 {
            return .maintenanceRequired(ticket: outcome.retirementTicket)
        }
        return .completed
    }

    func discardPendingPrepared(bridgeGeneration: UInt64) {
        guard let retained = lease, retained.bridgeGeneration == bridgeGeneration else { return }
        _ = EAUM1RuntimeDiscardPendingPrepared(retained.pointer)
    }

    func requestRecoverableStop(
        reason: M1RetirementStopReason,
        bridgeGeneration: UInt64
    ) async {
        guard lease?.bridgeGeneration == bridgeGeneration else { return }
        await stopHandler(reason, bridgeGeneration)
    }
}
