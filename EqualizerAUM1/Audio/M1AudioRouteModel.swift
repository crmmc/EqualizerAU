import Foundation

struct M1AudioRouteGeneration: Hashable, Sendable {
    let rawValue: UInt64
}

enum M1HALResourceKind: String, Sendable {
    case processTap
    case aggregateDevice
}

struct M1HALResourceDescriptor: Equatable, Sendable {
    let ownershipToken: UUID
    let generation: M1AudioRouteGeneration
    let kind: M1HALResourceKind
    let objectID: UInt32
    let persistentUID: String
}

struct M1HALPCMFormat: Equatable, Sendable {
    let sampleRate: Double
    let channelCount: UInt32
    let isNativeFloat32: Bool
    let isPacked: Bool
    let isNonInterleaved: Bool
    let framesPerPacket: UInt32
    let bytesPerFrame: UInt32
    let bytesPerPacket: UInt32

    var isSupported: Bool {
        let expectedBytesPerFrame: UInt32
        if isNonInterleaved {
            expectedBytesPerFrame = UInt32(MemoryLayout<Float>.size)
        } else {
            let result = channelCount.multipliedReportingOverflow(
                by: UInt32(MemoryLayout<Float>.size)
            )
            guard !result.overflow else { return false }
            expectedBytesPerFrame = result.partialValue
        }
        return sampleRate.isFinite
            && sampleRate > 0
            && channelCount > 0
            && isNativeFloat32
            && isPacked
            && framesPerPacket == 1
            && bytesPerFrame == expectedBytesPerFrame
            && bytesPerPacket == bytesPerFrame
    }
}

struct M1HALOutputDeviceData: Equatable, Sendable {
    let objectID: UInt32
    let uid: String
    let name: String
    let isAlive: Bool
    let sampleRate: Double
    let maximumFrameCount: Int
    let bufferChannelCounts: [Int]
    let semanticPositions: [M1SpeakerPosition?]
}

struct M1OutputDeviceSnapshot: Equatable, Sendable {
    let generation: M1AudioRouteGeneration
    let objectID: UInt32
    let uid: String
    let name: String
    let layout: M1OutputLayoutSnapshot
}

struct M1HALTapData: Equatable, Sendable {
    let uid: String
    let format: M1HALPCMFormat
}

struct M1ProcessTapResource: Equatable, Sendable {
    let descriptor: M1HALResourceDescriptor
    let excludedProcessObjectID: UInt32
    let outputDeviceUID: String
    let format: M1HALPCMFormat
}

struct M1HALAggregateData: Equatable, Sendable {
    let uid: String
    let tapUIDs: [String]
    let format: M1HALPCMFormat
    let maximumFrameCount: Int
    let bufferChannelCounts: [Int]
}

struct M1AggregateResource: Equatable, Sendable {
    let descriptor: M1HALResourceDescriptor
    let outputDeviceUID: String
    let tapUID: String
    let format: M1HALPCMFormat
    let maximumFrameCount: Int
    let bufferChannelCounts: [Int]
}

struct M1ProcessTapRequest: Equatable, Sendable {
    let name: String
    let outputDeviceUID: String
    let outputStreamIndex: UInt32
    let excludedProcessObjectID: UInt32
    let isPrivate: Bool
    let isMuted: Bool
}

struct M1AggregateRequest: Equatable, Sendable {
    let uid: String
    let name: String
    let tapUID: String
    let isPrivate: Bool
    let isStacked: Bool
    let tapAutoStart: Bool
    let tapDriftCompensation: Bool
}

enum M1AudioRouteError: Error, Equatable, Sendable {
    case noOutputDevice
    case audioCapturePermissionDenied
    case invalidOutputDevice(String)
    case invalidTap(String)
    case invalidAggregate(String)
    case generationMismatch
    case staleResource
}

protocol M1HALRouteOperations: Sendable {
    func readDefaultOutputDevice() throws -> M1HALOutputDeviceData
    func readCurrentProcessObjectID() throws -> UInt32
    func createProcessTap(_ request: M1ProcessTapRequest) throws -> UInt32
    func probeAndMuteProcessTap(_ objectID: UInt32) throws
    func verifyProcessTapCapturePermission(_ objectID: UInt32) throws
    func readProcessTap(_ objectID: UInt32) throws -> M1HALTapData
    func readProcessTapUID(_ objectID: UInt32) throws -> String
    func destroyProcessTap(_ objectID: UInt32) throws
    func createAggregateDevice(_ request: M1AggregateRequest) throws -> UInt32
    func readAggregateDevice(_ objectID: UInt32) throws -> M1HALAggregateData
    func readAggregateDeviceUID(_ objectID: UInt32) throws -> String
    func destroyAggregateDevice(_ objectID: UInt32) throws
}

actor M1AudioRouteResourceController {
    private struct PendingOwnership: Sendable {
        let token: UUID
        let persistentUID: String?
    }

    private let operations: any M1HALRouteOperations
    private var activeTapTokens: [UInt32: UUID] = [:]
    private var pendingTapTokens: [UInt32: PendingOwnership] = [:]
    private var supersededTapTokens: Set<UUID> = []
    private var activeAggregateTokens: [UInt32: UUID] = [:]
    private var pendingAggregateTokens: [UInt32: PendingOwnership] = [:]

    init(operations: any M1HALRouteOperations) {
        self.operations = operations
    }

    func discoverOutput(generation: M1AudioRouteGeneration) throws -> M1OutputDeviceSnapshot {
        let value = try operations.readDefaultOutputDevice()
        guard value.objectID != 0 else { throw M1AudioRouteError.noOutputDevice }
        guard !value.uid.isEmpty, value.isAlive else {
            throw M1AudioRouteError.invalidOutputDevice("missing UID or device is not alive")
        }

        guard let layout = M1OutputLayoutSnapshot(
            sampleRate: value.sampleRate,
            maximumFrameCount: value.maximumFrameCount,
            bufferChannelCounts: value.bufferChannelCounts,
            semanticPositionsByChannelIndex: value.semanticPositions
        ) else {
            throw M1AudioRouteError.invalidOutputDevice("invalid output layout")
        }

        return M1OutputDeviceSnapshot(
            generation: generation,
            objectID: value.objectID,
            uid: value.uid,
            name: value.name,
            layout: layout
        )
    }

    func createTap(
        generation: M1AudioRouteGeneration,
        output: M1OutputDeviceSnapshot,
        handoverGuard: M1ProcessTapResource? = nil
    ) throws -> M1ProcessTapResource {
        guard generation == output.generation else { throw M1AudioRouteError.generationMismatch }
        guard pendingTapTokens.isEmpty else {
            throw M1AudioRouteError.staleResource
        }
        if let handoverGuard {
            guard activeTapTokens.count == 1,
                  handoverGuard.descriptor.kind == .processTap,
                  handoverGuard.descriptor.generation != generation,
                  handoverGuard.outputDeviceUID == output.uid,
                  activeTapTokens[handoverGuard.descriptor.objectID]
                    == handoverGuard.descriptor.ownershipToken
            else {
                throw M1AudioRouteError.staleResource
            }
        } else if !activeTapTokens.isEmpty {
            throw M1AudioRouteError.staleResource
        }
        let processObjectID = try operations.readCurrentProcessObjectID()
        guard processObjectID != 0 else {
            throw M1AudioRouteError.invalidTap("current process object is unavailable")
        }

        let request = M1ProcessTapRequest(
            name: "EqualizerAU M1 System Tap",
            outputDeviceUID: output.uid,
            outputStreamIndex: 0,
            excludedProcessObjectID: processObjectID,
            isPrivate: true,
            isMuted: false
        )
        let objectID = try operations.createProcessTap(request)
        guard objectID != 0 else { throw M1AudioRouteError.invalidTap("HAL returned object 0") }
        var supersededToken: UUID?
        if let existingToken = activeTapTokens[objectID] {
            guard handoverGuard?.descriptor.objectID == objectID,
                  handoverGuard?.descriptor.ownershipToken == existingToken
            else {
                throw M1AudioRouteError.staleResource
            }
            activeTapTokens.removeValue(forKey: objectID)
            supersededTapTokens.insert(existingToken)
            supersededToken = existingToken
        }

        let token = UUID()
        activeTapTokens[objectID] = token
        var persistentUID: String?
        do {
            persistentUID = try operations.readProcessTapUID(objectID)
            let tap = try operations.readProcessTap(objectID)
            guard tap.uid == persistentUID, !tap.uid.isEmpty, tap.format.isSupported else {
                throw M1AudioRouteError.invalidTap("unsupported tap UID or format")
            }
            guard tap.format.sampleRate == output.layout.sampleRate,
                  tap.format.channelCount == UInt32(output.layout.channels.count)
            else {
                throw M1AudioRouteError.invalidTap("tap format does not match output snapshot")
            }
            return M1ProcessTapResource(
                descriptor: M1HALResourceDescriptor(
                    ownershipToken: token,
                    generation: generation,
                    kind: .processTap,
                    objectID: objectID,
                    persistentUID: tap.uid
                ),
                excludedProcessObjectID: processObjectID,
                outputDeviceUID: output.uid,
                format: tap.format
            )
        } catch {
            do {
                if let persistentUID {
                    try destroyTap(objectID: objectID, token: token, persistentUID: persistentUID)
                } else {
                    try operations.destroyProcessTap(objectID)
                    activeTapTokens.removeValue(forKey: objectID)
                }
            } catch {
                if activeTapTokens[objectID] == token {
                    pendingTapTokens[objectID] = PendingOwnership(
                        token: token,
                        persistentUID: persistentUID
                    )
                }
            }
            throw error
        }
    }

    func prepareTapForCapture(_ routeTap: M1ProcessTapResource) throws {
        guard routeTap.descriptor.kind == .processTap,
              pendingTapTokens.isEmpty,
              activeTapTokens[routeTap.descriptor.objectID]
                == routeTap.descriptor.ownershipToken
        else {
            throw M1AudioRouteError.staleResource
        }
        try operations.probeAndMuteProcessTap(routeTap.descriptor.objectID)
    }

    func verifyCapturePermission(using routeTap: M1ProcessTapResource) throws {
        guard routeTap.descriptor.kind == .processTap,
              activeTapTokens.count == 1,
              pendingTapTokens.isEmpty,
              activeTapTokens[routeTap.descriptor.objectID]
                == routeTap.descriptor.ownershipToken
        else {
            throw M1AudioRouteError.staleResource
        }
        try operations.verifyProcessTapCapturePermission(routeTap.descriptor.objectID)
    }

    func createAggregate(
        generation: M1AudioRouteGeneration,
        output: M1OutputDeviceSnapshot,
        tap: M1ProcessTapResource
    ) throws -> M1AggregateResource {
        guard generation == output.generation,
              generation == tap.descriptor.generation
        else {
            throw M1AudioRouteError.generationMismatch
        }
        guard tap.descriptor.kind == .processTap,
              activeTapTokens[tap.descriptor.objectID] == tap.descriptor.ownershipToken
        else {
            throw M1AudioRouteError.staleResource
        }
        guard activeAggregateTokens.isEmpty, pendingAggregateTokens.isEmpty else {
            throw M1AudioRouteError.staleResource
        }

        let uid = "com.ruimingchen.EqualizerAU.m1.aggregate.\(generation.rawValue).\(UUID().uuidString)"
        let request = M1AggregateRequest(
            uid: uid,
            name: "EqualizerAU M1 Tap Aggregate",
            tapUID: tap.descriptor.persistentUID,
            isPrivate: true,
            isStacked: false,
            tapAutoStart: false,
            tapDriftCompensation: true
        )
        let objectID = try operations.createAggregateDevice(request)
        guard objectID != 0 else {
            throw M1AudioRouteError.invalidAggregate("HAL returned object 0")
        }
        guard activeAggregateTokens[objectID] == nil else {
            throw M1AudioRouteError.staleResource
        }

        let token = UUID()
        activeAggregateTokens[objectID] = token
        do {
            let aggregate = try operations.readAggregateDevice(objectID)
            guard aggregate.uid == uid,
                  aggregate.tapUIDs == [tap.descriptor.persistentUID],
                  aggregate.format.isSupported,
                  aggregate.format.sampleRate == output.layout.sampleRate,
                  aggregate.format.channelCount == UInt32(output.layout.channels.count),
                  aggregate.maximumFrameCount > 0,
                  !aggregate.bufferChannelCounts.isEmpty,
                  aggregate.bufferChannelCounts.allSatisfy({ $0 > 0 }),
                  aggregate.bufferChannelCounts.reduce(0, +) == output.layout.channels.count
            else {
                throw M1AudioRouteError.invalidAggregate("aggregate identity, tap list or format mismatch")
            }
            return M1AggregateResource(
                descriptor: M1HALResourceDescriptor(
                    ownershipToken: token,
                    generation: generation,
                    kind: .aggregateDevice,
                    objectID: objectID,
                    persistentUID: aggregate.uid
                ),
                outputDeviceUID: output.uid,
                tapUID: tap.descriptor.persistentUID,
                format: aggregate.format,
                maximumFrameCount: aggregate.maximumFrameCount,
                bufferChannelCounts: aggregate.bufferChannelCounts
            )
        } catch {
            do {
                try destroyAggregate(objectID: objectID, token: token, persistentUID: uid)
            } catch {
                if activeAggregateTokens[objectID] == token {
                    pendingAggregateTokens[objectID] = PendingOwnership(
                        token: token,
                        persistentUID: uid
                    )
                }
            }
            throw error
        }
    }

    func destroyAggregate(_ resource: M1AggregateResource) throws {
        guard resource.descriptor.kind == .aggregateDevice,
              activeAggregateTokens[resource.descriptor.objectID] == resource.descriptor.ownershipToken
        else {
            throw M1AudioRouteError.staleResource
        }
        try destroyAggregate(
            objectID: resource.descriptor.objectID,
            token: resource.descriptor.ownershipToken,
            persistentUID: resource.descriptor.persistentUID
        )
    }

    func destroyTap(_ resource: M1ProcessTapResource) throws {
        guard resource.descriptor.kind == .processTap else {
            throw M1AudioRouteError.staleResource
        }
        if supersededTapTokens.remove(resource.descriptor.ownershipToken) != nil { return }
        guard activeTapTokens[resource.descriptor.objectID] == resource.descriptor.ownershipToken else {
            throw M1AudioRouteError.staleResource
        }
        try destroyTap(
            objectID: resource.descriptor.objectID,
            token: resource.descriptor.ownershipToken,
            persistentUID: resource.descriptor.persistentUID
        )
    }

    func cleanupPendingResources() throws {
        for objectID in pendingAggregateTokens.keys.sorted() {
            guard let ownership = pendingAggregateTokens[objectID] else { continue }
            if activeAggregateTokens[objectID] == ownership.token {
                guard let persistentUID = ownership.persistentUID else {
                    throw M1AudioRouteError.invalidAggregate("pending aggregate identity is unavailable")
                }
                try destroyAggregate(
                    objectID: objectID,
                    token: ownership.token,
                    persistentUID: persistentUID
                )
            } else {
                pendingAggregateTokens.removeValue(forKey: objectID)
            }
        }
        for objectID in pendingTapTokens.keys.sorted() {
            guard let ownership = pendingTapTokens[objectID] else { continue }
            if activeTapTokens[objectID] == ownership.token {
                guard let persistentUID = ownership.persistentUID else {
                    throw M1AudioRouteError.invalidTap("pending tap identity is unavailable")
                }
                try destroyTap(
                    objectID: objectID,
                    token: ownership.token,
                    persistentUID: persistentUID
                )
                pendingTapTokens.removeValue(forKey: objectID)
            }
        }
    }

    func ownsTap(_ resource: M1ProcessTapResource) -> Bool {
        resource.descriptor.kind == .processTap
            && activeTapTokens[resource.descriptor.objectID] == resource.descriptor.ownershipToken
    }

    func hasPendingResources() -> Bool {
        !pendingAggregateTokens.isEmpty || !pendingTapTokens.isEmpty
    }

    private func destroyAggregate(objectID: UInt32, token: UUID, persistentUID: String) throws {
        guard activeAggregateTokens[objectID] == token else { throw M1AudioRouteError.staleResource }
        guard try operations.readAggregateDeviceUID(objectID) == persistentUID else {
            activeAggregateTokens.removeValue(forKey: objectID)
            pendingAggregateTokens.removeValue(forKey: objectID)
            return
        }
        try operations.destroyAggregateDevice(objectID)
        activeAggregateTokens.removeValue(forKey: objectID)
        pendingAggregateTokens.removeValue(forKey: objectID)
    }

    private func destroyTap(objectID: UInt32, token: UUID, persistentUID: String) throws {
        guard activeTapTokens[objectID] == token else { throw M1AudioRouteError.staleResource }
        guard try operations.readProcessTapUID(objectID) == persistentUID else {
            activeTapTokens.removeValue(forKey: objectID)
            pendingTapTokens.removeValue(forKey: objectID)
            return
        }
        try operations.destroyProcessTap(objectID)
        activeTapTokens.removeValue(forKey: objectID)
        pendingTapTokens.removeValue(forKey: objectID)
    }
}
