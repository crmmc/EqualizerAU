import Foundation

struct M1RuntimeConfigurationGenerations: Equatable, Sendable {
    let active: UInt64?
    let pending: UInt64?
}

struct M1RuntimeCounters: Equatable, Sendable {
    let nonFiniteInputSamples: UInt64
    let saturatedOutputSamples: UInt64
    let invalidProcessCalls: UInt64
    let overlappingCallbacks: UInt64
}

actor M1RuntimeLeaseAccess: M1RetirementMaintenanceAccess {
    typealias StopHandler = @Sendable (M1RetirementStopReason, UInt64) async -> Void

    private var lease: M1RuntimeHandleLease?
    private var activeConfigurationGeneration: UInt64?
    private var pendingConfigurationGeneration: UInt64?
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
        defer {
            lease = nil
            activeConfigurationGeneration = nil
            pendingConfigurationGeneration = nil
        }
        return lease
    }

    func publish(
        linearGainsByChannel: [Float],
        configurationGeneration: UInt64,
        bridgeGeneration: UInt64
    ) throws -> M1RuntimePreparedPublication {
        guard let retained = lease, retained.bridgeGeneration == bridgeGeneration else {
            throw M1AudioIOError.generationMismatch
        }
        guard let count = UInt32(exactly: linearGainsByChannel.count), count > 0 else {
            throw M1AudioIOError.invalidConfiguration("invalid Prepared channel count")
        }
        var prepared: OpaquePointer?
        let createStatus = linearGainsByChannel.withUnsafeBufferPointer { values in
            EAUM1PreparedStateCreate(values.baseAddress, count, &prepared)
        }
        guard createStatus == EAUM1StatusOK, prepared != nil else {
            throw M1AudioIOError.invalidConfiguration("Prepared creation failed: \(createStatus)")
        }
        var outcome = EAUM1PublicationOutcome()
        let status = EAUM1RuntimePublishPrepared(retained.pointer, &prepared, &outcome)
        if let prepared { EAUM1PreparedStateDestroy(prepared) }
        guard status == EAUM1StatusOK else {
            throw M1AudioIOError.invalidConfiguration("Prepared publication failed: \(status)")
        }
        let retirementTicket = outcome.flags & UInt32(EAUM1PublicationMaintenanceRequired) != 0
            ? outcome.retirementTicket
            : nil
        if outcome.flags & UInt32(EAUM1PublicationCandidatePublished) != 0 {
            activeConfigurationGeneration = configurationGeneration
            return M1RuntimePreparedPublication(
                disposition: .active,
                retirementTicket: retirementTicket
            )
        }
        if outcome.flags & UInt32(EAUM1PublicationCandidateCoalesced) != 0 {
            pendingConfigurationGeneration = configurationGeneration
            return M1RuntimePreparedPublication(
                disposition: .pending,
                retirementTicket: retirementTicket
            )
        }
        throw M1AudioIOError.invalidState("Prepared publication returned no disposition")
    }

    func setEffectsEnabled(_ enabled: Bool, bridgeGeneration: UInt64) throws {
        guard let retained = lease, retained.bridgeGeneration == bridgeGeneration else {
            throw M1AudioIOError.generationMismatch
        }
        let status = EAUM1RuntimeSetEffectsEnabled(retained.pointer, enabled ? 1 : 0)
        guard status == EAUM1StatusOK else {
            throw M1AudioIOError.invalidState("effects update failed: \(status)")
        }
    }

    func configurationGenerations(
        bridgeGeneration: UInt64
    ) -> M1RuntimeConfigurationGenerations? {
        guard lease?.bridgeGeneration == bridgeGeneration else { return nil }
        return M1RuntimeConfigurationGenerations(
            active: activeConfigurationGeneration,
            pending: pendingConfigurationGeneration
        )
    }

    func diagnostics(bridgeGeneration: UInt64) throws -> M1RuntimeCounters {
        guard let retained = lease, retained.bridgeGeneration == bridgeGeneration else {
            throw M1AudioIOError.generationMismatch
        }
        var runtime = EAUM1RuntimeDiagnostics()
        var concurrency = EAUM1ConcurrencyDiagnostics()
        let runtimeStatus = EAUM1RuntimeCopyDiagnostics(retained.pointer, &runtime)
        let concurrencyStatus = EAUM1RuntimeCopyConcurrencyDiagnostics(retained.pointer, &concurrency)
        guard runtimeStatus == EAUM1StatusOK, concurrencyStatus == EAUM1StatusOK else {
            throw M1AudioIOError.invalidState("Runtime diagnostics unavailable")
        }
        return M1RuntimeCounters(
            nonFiniteInputSamples: runtime.nonFiniteInputSampleCount,
            saturatedOutputSamples: runtime.saturatedOutputSampleCount,
            invalidProcessCalls: runtime.invalidProcessCallCount,
            overlappingCallbacks: concurrency.overlappingCallbackCount
        )
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
        if outcome.flags & UInt32(EAUM1PublicationCandidatePublished) != 0 {
            activeConfigurationGeneration = pendingConfigurationGeneration
            pendingConfigurationGeneration = nil
        }
        if outcome.flags & UInt32(EAUM1PublicationMaintenanceRequired) != 0 {
            return .maintenanceRequired(ticket: outcome.retirementTicket)
        }
        return .completed
    }

    func discardPendingPrepared(bridgeGeneration: UInt64) {
        guard let retained = lease, retained.bridgeGeneration == bridgeGeneration else { return }
        _ = EAUM1RuntimeDiscardPendingPrepared(retained.pointer)
        pendingConfigurationGeneration = nil
    }

    func requestRecoverableStop(
        reason: M1RetirementStopReason,
        bridgeGeneration: UInt64
    ) async {
        guard lease?.bridgeGeneration == bridgeGeneration else { return }
        await stopHandler(reason, bridgeGeneration)
    }
}
