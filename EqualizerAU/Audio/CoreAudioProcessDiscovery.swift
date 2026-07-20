import CoreAudio
import Foundation

struct CoreAudioProcessSnapshot: Equatable, Sendable {
    let outputDeviceID: AudioObjectID
    let selfProcessObjectID: AudioObjectID
    let processObjectIDs: [AudioObjectID]
}

enum CoreAudioProcessDiscoveryError: Error, Equatable, LocalizedError, Sendable {
    case noEligibleOutputProcesses(deviceUID: String)
    case malformedObjectIDList(selector: AudioObjectPropertySelector)

    var errorDescription: String? {
        switch self {
        case let .noEligibleOutputProcesses(deviceUID):
            return "No active Core Audio source processes were found for output device '\(deviceUID)'."
        case let .malformedObjectIDList(selector):
            return "Core Audio returned a malformed object list for \(fourCC(selector))."
        }
    }
}

protocol CoreAudioProcessDiscovering: Sendable {
    func snapshot(output: AudioDeviceSnapshot) async throws -> CoreAudioProcessSnapshot
}

actor CoreAudioProcessDiscovery: CoreAudioProcessDiscovering {
    private let reader: HALPropertyReader
    private let processID: pid_t

    init(
        reader: HALPropertyReader = HALPropertyReader(),
        processID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) {
        self.reader = reader
        self.processID = processID
    }

    func snapshot(output: AudioDeviceSnapshot) throws -> CoreAudioProcessSnapshot {
        let selfProcessObjectID: AudioObjectID = try reader.readQualifiedValue(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: HALPropertyAddress(selector: kAudioHardwarePropertyTranslatePIDToProcessObject),
            operation: "Translate EqualizerAU PID to Core Audio process object",
            qualifier: processID,
            initialValue: AudioObjectID(kAudioObjectUnknown)
        )
        guard selfProcessObjectID != kAudioObjectUnknown else {
            throw HALStatusError(
                operation: "Validate EqualizerAU Core Audio process object",
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: HALPropertyAddress(selector: kAudioHardwarePropertyTranslatePIDToProcessObject),
                status: kAudioHardwareBadObjectError
            )
        }
        let processIDs = try readObjectIDs(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: HALPropertyAddress(selector: kAudioHardwarePropertyProcessObjectList),
            operation: "Read Core Audio process object list"
        )

        var eligible: [AudioObjectID] = []
        for processObjectID in processIDs where processObjectID != selfProcessObjectID {
            do {
                let isRunningOutput: UInt32 = try reader.readValue(
                    objectID: processObjectID,
                    address: HALPropertyAddress(selector: kAudioProcessPropertyIsRunningOutput),
                    operation: "Read process output-running state",
                    initialValue: 0
                )
                guard isRunningOutput != 0 else { continue }

                let devices = try readObjectIDs(
                    objectID: processObjectID,
                    address: HALPropertyAddress(
                        selector: kAudioProcessPropertyDevices,
                        scope: kAudioObjectPropertyScopeOutput
                    ),
                    operation: "Read process output devices"
                )
                if devices.contains(output.objectID) {
                    eligible.append(processObjectID)
                }
            } catch let error as HALStatusError where error.status == kAudioHardwareBadObjectError {
                // A process can leave the HAL between the system-list and property reads.
                continue
            }
        }

        eligible.sort()
        guard !eligible.isEmpty else {
            throw CoreAudioProcessDiscoveryError.noEligibleOutputProcesses(deviceUID: output.uid)
        }
        return CoreAudioProcessSnapshot(
            outputDeviceID: output.objectID,
            selfProcessObjectID: selfProcessObjectID,
            processObjectIDs: eligible
        )
    }

    private func readObjectIDs(
        objectID: AudioObjectID,
        address: HALPropertyAddress,
        operation: String
    ) throws -> [AudioObjectID] {
        let data = try reader.readData(
            objectID: objectID,
            address: address,
            operation: operation,
            allowEmpty: true
        )
        guard data.count.isMultiple(of: MemoryLayout<AudioObjectID>.size) else {
            throw CoreAudioProcessDiscoveryError.malformedObjectIDList(selector: address.selector)
        }
        return data.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: MemoryLayout<AudioObjectID>.size).map {
                bytes.loadUnaligned(fromByteOffset: $0, as: AudioObjectID.self)
            }
        }
    }
}
