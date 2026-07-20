import CoreAudio
import Foundation

enum ProcessTapMuteBehavior: Equatable, Sendable {
    case unmuted
    case muted
    case mutedWhenTapped

    var coreAudioValue: CATapMuteBehavior {
        switch self {
        case .unmuted: .unmuted
        case .muted: .muted
        case .mutedWhenTapped: .mutedWhenTapped
        }
    }
}

struct ProcessTapConfiguration: Equatable, Sendable {
    let generation: AudioGeneration
    let name: String
    let muteBehavior: ProcessTapMuteBehavior
    let outputDeviceUID: String?
    let outputStreamIndex: UInt
    let includedProcessObjectIDs: [AudioObjectID]?

    init(
        generation: AudioGeneration,
        name: String = "EqualizerAU System Audio Tap",
        muteBehavior: ProcessTapMuteBehavior = .mutedWhenTapped,
        outputDeviceUID: String? = nil,
        outputStreamIndex: UInt = 0,
        includedProcessObjectIDs: [AudioObjectID]? = nil
    ) {
        self.generation = generation
        self.name = name
        self.muteBehavior = muteBehavior
        self.outputDeviceUID = outputDeviceUID
        self.outputStreamIndex = outputStreamIndex
        self.includedProcessObjectIDs = includedProcessObjectIDs
    }
}

struct ProcessTapResource: Sendable {
    let descriptor: AudioResourceDescriptor
    let selfProcessObjectID: AudioObjectID
    let format: AudioStreamBasicDescription
    let muteBehavior: ProcessTapMuteBehavior

    var objectID: AudioObjectID { descriptor.objectID }
    var uid: String { descriptor.persistentUID ?? "" }
    var ownershipToken: UUID { descriptor.ownershipToken }
}

struct CoreAudioProcessOutputState: Equatable, Sendable {
    let processObjectID: AudioObjectID
    let isRunningOutput: Bool
    let outputDeviceIDs: [AudioObjectID]
}

struct ProcessTapLifecycleError: Error, Equatable, LocalizedError, Sendable {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        "\(operation) failed: OSStatus \(status) (\(fourCC(UInt32(bitPattern: status))))"
    }
}

protocol ProcessTapOperations: Sendable {
    func create(description: CATapDescription, tapID: inout AudioObjectID) -> OSStatus
    func destroy(tapID: AudioObjectID) -> OSStatus
}

protocol ProcessTapControlling: Sendable {
    func currentProcessObjectID() async throws -> AudioObjectID
    func outputState(processObjectID: AudioObjectID) async throws -> CoreAudioProcessOutputState
    func activeOutputProcessObjectIDs(deviceID: AudioObjectID) async throws -> [AudioObjectID]
    func create(configuration: ProcessTapConfiguration) async throws -> ProcessTapResource
    func destroy(_ resource: ProcessTapResource) async throws
    func cleanupPendingCreation() async throws
}

struct SystemProcessTapOperations: ProcessTapOperations {
    func create(description: CATapDescription, tapID: inout AudioObjectID) -> OSStatus {
        AudioHardwareCreateProcessTap(description, &tapID)
    }

    func destroy(tapID: AudioObjectID) -> OSStatus {
        AudioHardwareDestroyProcessTap(tapID)
    }
}

actor ProcessTapController: ProcessTapControlling {
    private let propertyReader: HALPropertyReader
    private let operations: any ProcessTapOperations
    private let processID: pid_t
    private var activeTapTokens: [AudioObjectID: UUID] = [:]
    private var pendingCreationTapTokens: [AudioObjectID: UUID] = [:]

    init(
        propertyReader: HALPropertyReader = HALPropertyReader(),
        operations: any ProcessTapOperations = SystemProcessTapOperations(),
        processID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) {
        self.propertyReader = propertyReader
        self.operations = operations
        self.processID = processID
    }

    func currentProcessObjectID() throws -> AudioObjectID {
        let processObjectID = try translateProcessID()
        guard processObjectID != kAudioObjectUnknown else {
            throw ProcessTapLifecycleError(
                operation: "Translate current PID to Core Audio process object",
                status: kAudioHardwareBadObjectError
            )
        }
        return processObjectID
    }

    func outputState(processObjectID: AudioObjectID) throws -> CoreAudioProcessOutputState {
        guard processObjectID != kAudioObjectUnknown else {
            throw ProcessTapLifecycleError(
                operation: "Validate Core Audio process output owner",
                status: kAudioHardwareBadObjectError
            )
        }
        let running: UInt32 = try propertyReader.readValue(
            objectID: processObjectID,
            address: HALPropertyAddress(selector: kAudioProcessPropertyIsRunningOutput),
            operation: "Read current-process output-running state",
            initialValue: 0
        )
        let deviceData = try propertyReader.readData(
            objectID: processObjectID,
            address: HALPropertyAddress(
                selector: kAudioProcessPropertyDevices,
                scope: kAudioObjectPropertyScopeOutput
            ),
            operation: "Read current-process output devices",
            allowEmpty: true
        )
        guard deviceData.count.isMultiple(of: MemoryLayout<AudioObjectID>.size) else {
            throw ProcessTapLifecycleError(
                operation: "Validate current-process output device list",
                status: kAudio_ParamError
            )
        }
        let deviceIDs = deviceData.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: MemoryLayout<AudioObjectID>.size).map {
                bytes.loadUnaligned(fromByteOffset: $0, as: AudioObjectID.self)
            }
        }
        return CoreAudioProcessOutputState(
            processObjectID: processObjectID,
            isRunningOutput: running != 0,
            outputDeviceIDs: deviceIDs.sorted()
        )
    }

    func activeOutputProcessObjectIDs(deviceID: AudioObjectID) throws -> [AudioObjectID] {
        guard deviceID != kAudioObjectUnknown else {
            throw ProcessTapLifecycleError(
                operation: "Validate target output device",
                status: kAudioHardwareBadObjectError
            )
        }
        let processData = try propertyReader.readData(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: HALPropertyAddress(selector: kAudioHardwarePropertyProcessObjectList),
            operation: "Read active-output process object list",
            allowEmpty: true
        )
        guard processData.count.isMultiple(of: MemoryLayout<AudioObjectID>.size) else {
            throw ProcessTapLifecycleError(
                operation: "Validate active-output process object list",
                status: kAudio_ParamError
            )
        }
        let processObjectIDs = processData.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: MemoryLayout<AudioObjectID>.size).map {
                bytes.loadUnaligned(fromByteOffset: $0, as: AudioObjectID.self)
            }
        }

        var active: [AudioObjectID] = []
        for processObjectID in processObjectIDs {
            do {
                let state = try outputState(processObjectID: processObjectID)
                if state.isRunningOutput, state.outputDeviceIDs.contains(deviceID) {
                    active.append(processObjectID)
                }
            } catch let error as HALStatusError where error.status == kAudioHardwareBadObjectError {
                // The process can disappear between reading the list and its properties.
                continue
            }
        }
        return active.sorted()
    }

    func create(configuration: ProcessTapConfiguration) throws -> ProcessTapResource {
        let selfProcessObjectID = try currentProcessObjectID()

        let description: CATapDescription
        if let includedProcessObjectIDs = configuration.includedProcessObjectIDs {
            guard let outputDeviceUID = configuration.outputDeviceUID,
                  !outputDeviceUID.isEmpty,
                  !includedProcessObjectIDs.isEmpty,
                  !includedProcessObjectIDs.contains(selfProcessObjectID)
            else {
                throw ProcessTapLifecycleError(
                    operation: "Validate inclusive Process Tap scope",
                    status: kAudio_ParamError
                )
            }
            description = CATapDescription(
                processes: includedProcessObjectIDs,
                deviceUID: outputDeviceUID,
                stream: configuration.outputStreamIndex
            )
        } else if let outputDeviceUID = configuration.outputDeviceUID {
            guard !outputDeviceUID.isEmpty else {
                throw ProcessTapLifecycleError(
                    operation: "Validate Process Tap output device scope",
                    status: kAudio_ParamError
                )
            }
            description = CATapDescription(
                excludingProcesses: [selfProcessObjectID],
                deviceUID: outputDeviceUID,
                stream: configuration.outputStreamIndex
            )
        } else {
            description = CATapDescription(
                stereoGlobalTapButExcludeProcesses: [selfProcessObjectID]
            )
        }
        description.name = configuration.name
        description.isPrivate = true
        description.muteBehavior = configuration.muteBehavior.coreAudioValue

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let createStatus = operations.create(description: description, tapID: &tapID)
        guard createStatus == noErr, tapID != kAudioObjectUnknown else {
            throw ProcessTapLifecycleError(
                operation: "AudioHardwareCreateProcessTap",
                status: createStatus == noErr ? kAudioHardwareBadObjectError : createStatus
            )
        }
        let ownershipToken = UUID()
        activeTapTokens[tapID] = ownershipToken

        do {
            let uid = try readTapUID(tapID)
            let format = try readTapFormat(tapID)
            guard isSupportedTapFormat(format) else {
                throw ProcessTapLifecycleError(
                    operation: "Validate native Float32 kAudioTapPropertyFormat",
                    status: kAudioDeviceUnsupportedFormatError
                )
            }

            return ProcessTapResource(
                descriptor: AudioResourceDescriptor(
                    ownershipToken: ownershipToken,
                    generation: configuration.generation,
                    kind: .processTap,
                    objectID: tapID,
                    persistentUID: uid
                ),
                selfProcessObjectID: selfProcessObjectID,
                format: format,
                muteBehavior: configuration.muteBehavior
            )
        } catch {
            do {
                try destroy(tapID: tapID, ownershipToken: ownershipToken)
            } catch {
                if activeTapTokens[tapID] == ownershipToken {
                    pendingCreationTapTokens[tapID] = ownershipToken
                }
            }
            throw error
        }
    }

    func destroy(_ resource: ProcessTapResource) throws {
        guard activeTapTokens[resource.objectID] == resource.ownershipToken else {
            throw ProcessTapLifecycleError(
                operation: "Reject stale Process Tap resource",
                status: kAudioHardwareBadObjectError
            )
        }
        try destroy(tapID: resource.objectID, ownershipToken: resource.ownershipToken)
    }

    private func destroy(tapID: AudioObjectID, ownershipToken: UUID) throws {
        guard activeTapTokens[tapID] == ownershipToken else {
            throw ProcessTapLifecycleError(
                operation: "Reject stale Process Tap resource",
                status: kAudioHardwareBadObjectError
            )
        }
        let status = operations.destroy(tapID: tapID)
        guard status == noErr else {
            throw ProcessTapLifecycleError(
                operation: "AudioHardwareDestroyProcessTap",
                status: status
            )
        }
        activeTapTokens.removeValue(forKey: tapID)
        pendingCreationTapTokens.removeValue(forKey: tapID)
    }

    func cleanupPendingCreation() async throws {
        for tapID in pendingCreationTapTokens.keys.sorted() {
            guard let pendingToken = pendingCreationTapTokens[tapID] else { continue }
            guard activeTapTokens[tapID] == pendingToken else {
                pendingCreationTapTokens.removeValue(forKey: tapID)
                continue
            }
            try destroy(tapID: tapID, ownershipToken: pendingToken)
        }
    }

    private func translateProcessID() throws -> AudioObjectID {
        try propertyReader.readQualifiedValue(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: HALPropertyAddress(
                selector: kAudioHardwarePropertyTranslatePIDToProcessObject
            ),
            operation: "Translate PID to Core Audio process object",
            qualifier: processID,
            initialValue: AudioObjectID(kAudioObjectUnknown)
        )
    }

    private func readTapUID(_ tapID: AudioObjectID) throws -> String {
        try propertyReader.readRetainedString(
            objectID: tapID,
            address: HALPropertyAddress(selector: kAudioTapPropertyUID),
            operation: "Read kAudioTapPropertyUID"
        )
    }

    private func readTapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        try propertyReader.readValue(
            objectID: tapID,
            address: HALPropertyAddress(selector: kAudioTapPropertyFormat),
            operation: "Read kAudioTapPropertyFormat",
            initialValue: AudioStreamBasicDescription()
        )
    }

    private func isSupportedTapFormat(_ format: AudioStreamBasicDescription) -> Bool {
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let (interleavedBytesPerFrame, overflow) = UInt32(MemoryLayout<Float>.size)
            .multipliedReportingOverflow(by: format.mChannelsPerFrame)
        guard !overflow else { return false }
        let expectedBytesPerFrame = nonInterleaved
            ? UInt32(MemoryLayout<Float>.size)
            : interleavedBytesPerFrame
        return format.mSampleRate.isFinite
            && format.mSampleRate > 0
            && format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mFramesPerPacket == 1
            && format.mChannelsPerFrame > 0
            && format.mBitsPerChannel == 32
            && format.mBytesPerFrame == expectedBytesPerFrame
            && format.mBytesPerPacket == expectedBytesPerFrame
    }
}
