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

enum M1RuntimeEffectsState: Equatable, Sendable {
    case active
    case fadingOut
    case bypassed
    case fadingIn
}

enum M1RuntimePreparedStateFactory {
    static func create(stagesByChannel: [[M1CompiledProcessingStage]]) throws -> OpaquePointer {
        guard let channelCount = UInt32(exactly: stagesByChannel.count), channelCount > 0 else {
            throw M1AudioIOError.invalidConfiguration("invalid Prepared channel count")
        }
        var stages: [EAUM1PreparedStage] = []
        var convolutionTaps: [[Float]] = []
        stages.reserveCapacity(stagesByChannel.reduce(0) { $0 + $1.count })
        for (channelIndex, channelStages) in stagesByChannel.enumerated() {
            guard channelStages.count <= Int(EAUM1_MAX_STAGES_PER_CHANNEL),
                  let channel = UInt32(exactly: channelIndex)
            else {
                throw M1AudioIOError.invalidConfiguration("Prepared stage capacity exceeded")
            }
            for stage in channelStages {
                switch stage {
                case let .gain(_, linearGain):
                    stages.append(
                        EAUM1PreparedStage(
                            kind: UInt32(EAUM1PreparedStageGain),
                            channelIndex: channel,
                            b0: linearGain,
                            b1: 0,
                            b2: 0,
                            a1: 0,
                            a2: 0
                        )
                    )
                case let .biquad(_, _, coefficients):
                    stages.append(
                        EAUM1PreparedStage(
                            kind: UInt32(EAUM1PreparedStageBiquad),
                            channelIndex: channel,
                            b0: coefficients.b0,
                            b1: coefficients.b1,
                            b2: coefficients.b2,
                            a1: coefficients.a1,
                            a2: coefficients.a2
                        )
                    )
                case let .convolution(_, taps):
                    let descriptorIndex = convolutionTaps.count
                    convolutionTaps.append(taps)
                    stages.append(
                        EAUM1PreparedStage(
                            kind: UInt32(EAUM1PreparedStageConvolution),
                            channelIndex: channel,
                            b0: Double(descriptorIndex),
                            b1: 0,
                            b2: 0,
                            a1: 0,
                            a2: 0
                        )
                    )
                }
            }
        }
        guard stages.count <= Int(EAUM1_MAX_PREPARED_STAGE_COUNT),
              let stageCount = UInt32(exactly: stages.count)
        else {
            throw M1AudioIOError.invalidConfiguration("Prepared total stage capacity exceeded")
        }

        var prepared: OpaquePointer?
        var convolutionDescriptors: [EAUM1PreparedConvolution] = []
        convolutionDescriptors.reserveCapacity(convolutionTaps.count)
        try Task.checkCancellation()
        let status = try withUnsafeConvolutionDescriptors(
            taps: convolutionTaps,
            index: 0,
            descriptors: &convolutionDescriptors
        ) { descriptors in
            stages.withUnsafeBufferPointer { stageValues in
                descriptors.withUnsafeBufferPointer { convolutionValues in
                    var description = EAUM1PreparedDescriptionV3(
                        channelCount: channelCount,
                        stageCount: stageCount,
                        stages: stageValues.baseAddress,
                        convolutionCount: UInt32(convolutionValues.count),
                        convolutions: convolutionValues.baseAddress
                    )
                    return EAUM1PreparedStateCreateV3(&description, &prepared)
                }
            }
        }
        guard status == EAUM1StatusOK, let prepared else {
            throw M1AudioIOError.invalidConfiguration("Prepared creation failed: \(status)")
        }
        do {
            try Task.checkCancellation()
        } catch {
            EAUM1PreparedStateDestroy(prepared)
            throw error
        }
        return prepared
    }

    private static func withUnsafeConvolutionDescriptors<Result>(
        taps: [[Float]],
        index: Int,
        descriptors: inout [EAUM1PreparedConvolution],
        _ body: ([EAUM1PreparedConvolution]) throws -> Result
    ) throws -> Result {
        guard index < taps.count else { return try body(descriptors) }
        return try taps[index].withUnsafeBufferPointer { values in
            guard let tapCount = UInt32(exactly: values.count) else {
                throw M1AudioIOError.invalidConfiguration("Convolution tap count is not representable")
            }
            descriptors.append(
                EAUM1PreparedConvolution(
                    tapCount: tapCount,
                    taps: values.baseAddress
                )
            )
            return try withUnsafeConvolutionDescriptors(
                taps: taps,
                index: index + 1,
                descriptors: &descriptors,
                body
            )
        }
    }
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
        stagesByChannel: [[M1CompiledProcessingStage]],
        configurationGeneration: UInt64,
        bridgeGeneration: UInt64
    ) throws -> M1RuntimePreparedPublication {
        guard let retained = lease, retained.bridgeGeneration == bridgeGeneration else {
            throw M1AudioIOError.generationMismatch
        }
        var prepared: OpaquePointer? = try M1RuntimePreparedStateFactory.create(
            stagesByChannel: stagesByChannel
        )
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

    func canReplaceWhileBypassed(bridgeGeneration: UInt64) throws -> Bool {
        guard let retained = lease, retained.bridgeGeneration == bridgeGeneration else {
            throw M1AudioIOError.generationMismatch
        }
        let status = EAUM1RuntimeCanReplacePreparedWhileBypassed(retained.pointer)
        if status == EAUM1StatusNotReady { return false }
        guard status == EAUM1StatusOK else {
            throw M1AudioIOError.invalidState("Bypassed replacement unavailable: \(status)")
        }
        return true
    }

    func replaceWhileBypassed(
        stagesByChannel: [[M1CompiledProcessingStage]],
        configurationGeneration: UInt64?,
        bridgeGeneration: UInt64
    ) throws -> Bool {
        guard let retained = lease, retained.bridgeGeneration == bridgeGeneration else {
            throw M1AudioIOError.generationMismatch
        }
        var prepared: OpaquePointer? = try M1RuntimePreparedStateFactory.create(
            stagesByChannel: stagesByChannel
        )
        var outcome = EAUM1PublicationOutcome()
        let status = EAUM1RuntimeReplacePreparedWhileBypassed(
            retained.pointer,
            &prepared,
            &outcome
        )
        if let prepared { EAUM1PreparedStateDestroy(prepared) }
        if status == EAUM1StatusNotReady { return false }
        guard status == EAUM1StatusOK,
              outcome.flags & UInt32(EAUM1PublicationCandidatePublished) != 0
        else {
            throw M1AudioIOError.invalidConfiguration("Bypassed replacement failed: \(status)")
        }
        if let configurationGeneration {
            activeConfigurationGeneration = configurationGeneration
            pendingConfigurationGeneration = nil
        }
        return true
    }

    func enableEffects(
        bridgeGeneration: UInt64,
        activationToken: M1EffectsActivationToken
    ) throws {
        guard let retained = lease, retained.bridgeGeneration == bridgeGeneration else {
            throw M1AudioIOError.generationMismatch
        }
        guard let status = activationToken.performIfCurrent({
            EAUM1RuntimeSetEffectsEnabled(retained.pointer, 1)
        }) else {
            throw CancellationError()
        }
        guard status == EAUM1StatusOK else {
            throw M1AudioIOError.invalidState("effects update failed: \(status)")
        }
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

    func effectsState(bridgeGeneration: UInt64) throws -> M1RuntimeEffectsState {
        guard let retained = lease, retained.bridgeGeneration == bridgeGeneration else {
            throw M1AudioIOError.generationMismatch
        }
        var state: EAUM1EffectsState = 0
        let status = EAUM1RuntimeCopyEffectsState(retained.pointer, &state)
        guard status == EAUM1StatusOK else {
            throw M1AudioIOError.invalidState("effects state unavailable: \(status)")
        }
        switch state {
        case EAUM1EffectsState(EAUM1EffectsStateActive): return .active
        case EAUM1EffectsState(EAUM1EffectsStateFadingOut): return .fadingOut
        case EAUM1EffectsState(EAUM1EffectsStateBypassed): return .bypassed
        case EAUM1EffectsState(EAUM1EffectsStateFadingIn): return .fadingIn
        default: throw M1AudioIOError.invalidState("unknown effects state: \(state)")
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
