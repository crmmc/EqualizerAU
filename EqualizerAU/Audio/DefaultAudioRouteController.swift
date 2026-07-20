import CoreAudio
import Foundation

struct DefaultAudioRouteJournal: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let virtualDeviceUID: String
    let originalOutputDeviceUID: String
    let originalSystemOutputDeviceUID: String

    init(
        virtualDeviceUID: String,
        originalOutputDeviceUID: String,
        originalSystemOutputDeviceUID: String
    ) {
        version = Self.currentVersion
        self.virtualDeviceUID = virtualDeviceUID
        self.originalOutputDeviceUID = originalOutputDeviceUID
        self.originalSystemOutputDeviceUID = originalSystemOutputDeviceUID
    }
}

struct DefaultAudioRouteResource: Equatable, Sendable {
    let generation: AudioGeneration
    let journal: DefaultAudioRouteJournal
}

enum DefaultAudioRouteError: Error, Equatable, LocalizedError, Sendable {
    case routeAlreadyActive
    case unresolvedDevice(uid: String)
    case verificationFailed(selector: String, expectedUID: String, actualUID: String)
    case invalidJournalVersion(Int)
    case cleanupFailed([String])

    var errorDescription: String? {
        switch self {
        case .routeAlreadyActive:
            return "A default audio route transaction is already active."
        case let .unresolvedDevice(uid):
            return "Core Audio could not resolve device UID '\(uid)'."
        case let .verificationFailed(selector, expectedUID, actualUID):
            return "Default \(selector) route verification failed: expected '\(expectedUID)', got '\(actualUID)'."
        case let .invalidJournalVersion(version):
            return "Unsupported audio route recovery journal version \(version)."
        case let .cleanupFailed(errors):
            return errors.joined(separator: " ")
        }
    }
}

protocol AudioRouteJournalStoring: Sendable {
    func load() async throws -> DefaultAudioRouteJournal?
    func save(_ journal: DefaultAudioRouteJournal) async throws
    func clear() async throws
}

actor FileAudioRouteJournalStore: AudioRouteJournalStoring {
    private let fileURL: URL

    init(fileURL: URL = FileAudioRouteJournalStore.defaultURL()) {
        self.fileURL = fileURL
    }

    func load() throws -> DefaultAudioRouteJournal? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(
            DefaultAudioRouteJournal.self,
            from: Data(contentsOf: fileURL)
        )
    }

    func save(_ journal: DefaultAudioRouteJournal) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(journal)
        try data.write(to: fileURL, options: .atomic)
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    nonisolated static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EqualizerAU", isDirectory: true)
            .appendingPathComponent("audio-route-recovery.json", isDirectory: false)
    }
}

protocol DefaultAudioRouteControlling: Sendable {
    func activate(
        virtualDevice: BlackHoleDeviceSnapshot,
        generation: AudioGeneration
    ) async throws -> DefaultAudioRouteResource
    func restore(_ resource: DefaultAudioRouteResource) async throws
    func recoverIfNeeded() async throws
}

actor DefaultAudioRouteController: DefaultAudioRouteControlling {
    private enum Selector: Sendable {
        case output
        case systemOutput

        var name: String {
            switch self {
            case .output: "output"
            case .systemOutput: "system output"
            }
        }

        var property: AudioObjectPropertySelector {
            switch self {
            case .output: kAudioHardwarePropertyDefaultOutputDevice
            case .systemOutput: kAudioHardwarePropertyDefaultSystemOutputDevice
            }
        }

        func originalUID(in journal: DefaultAudioRouteJournal) -> String {
            switch self {
            case .output: journal.originalOutputDeviceUID
            case .systemOutput: journal.originalSystemOutputDeviceUID
            }
        }
    }

    private static let selectors: [Selector] = [.output, .systemOutput]

    private let reader: HALPropertyReader
    private let writer: HALPropertyWriter
    private let journalStore: any AudioRouteJournalStoring
    private var active: DefaultAudioRouteResource?

    init(
        operations: any HALPropertyOperations = SystemHALPropertyOperations(),
        journalStore: any AudioRouteJournalStoring = FileAudioRouteJournalStore()
    ) {
        reader = HALPropertyReader(operations: operations)
        writer = HALPropertyWriter(operations: operations)
        self.journalStore = journalStore
    }

    func activate(
        virtualDevice: BlackHoleDeviceSnapshot,
        generation: AudioGeneration
    ) async throws -> DefaultAudioRouteResource {
        guard active == nil else { throw DefaultAudioRouteError.routeAlreadyActive }

        let journal = DefaultAudioRouteJournal(
            virtualDeviceUID: virtualDevice.uid,
            originalOutputDeviceUID: try currentUID(Self.selectors[0]),
            originalSystemOutputDeviceUID: try currentUID(Self.selectors[1])
        )
        try await journalStore.save(journal)
        let resource = DefaultAudioRouteResource(generation: generation, journal: journal)
        active = resource

        do {
            for selector in Self.selectors {
                try setAndVerify(selector, deviceID: virtualDevice.objectID, expectedUID: virtualDevice.uid)
            }
            return resource
        } catch let activationError {
            do {
                try await restore(resource)
            } catch let rollbackError {
                throw DefaultAudioRouteError.cleanupFailed([
                    "Route activation failed: \(activationError.localizedDescription)",
                    "Route rollback failed: \(rollbackError.localizedDescription)"
                ])
            }
            throw activationError
        }
    }

    func restore(_ resource: DefaultAudioRouteResource) async throws {
        var errors: [String] = []
        for selector in Self.selectors {
            do {
                let current = try currentUID(selector)
                guard current == resource.journal.virtualDeviceUID else { continue }
                let originalUID = selector.originalUID(in: resource.journal)
                let originalID = try resolve(uid: originalUID)
                try setAndVerify(selector, deviceID: originalID, expectedUID: originalUID)
            } catch {
                errors.append("Restore default \(selector.name): \(error.localizedDescription)")
            }
        }
        guard errors.isEmpty else { throw DefaultAudioRouteError.cleanupFailed(errors) }
        try await journalStore.clear()
        if active == resource { active = nil }
    }

    func recoverIfNeeded() async throws {
        guard let journal = try await journalStore.load() else { return }
        guard journal.version == DefaultAudioRouteJournal.currentVersion else {
            throw DefaultAudioRouteError.invalidJournalVersion(journal.version)
        }
        let recovery = DefaultAudioRouteResource(
            generation: AudioGeneration(rawValue: 0),
            journal: journal
        )
        active = recovery
        try await restore(recovery)
    }

    private func currentUID(_ selector: Selector) throws -> String {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        let deviceID: AudioObjectID = try reader.readValue(
            objectID: systemObjectID,
            address: HALPropertyAddress(selector: selector.property),
            operation: "Read default \(selector.name) device",
            initialValue: kAudioObjectUnknown
        )
        guard deviceID != kAudioObjectUnknown else {
            throw DefaultAudioRouteError.unresolvedDevice(uid: "<default \(selector.name)>")
        }
        return try reader.readRetainedString(
            objectID: deviceID,
            address: HALPropertyAddress(selector: kAudioDevicePropertyDeviceUID),
            operation: "Read default \(selector.name) UID"
        )
    }

    private func resolve(uid: String) throws -> AudioObjectID {
        let cfUID = uid as CFString
        let deviceID: AudioObjectID = try reader.readQualifiedValue(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: HALPropertyAddress(selector: kAudioHardwarePropertyTranslateUIDToDevice),
            operation: "Resolve audio device UID",
            qualifier: cfUID,
            initialValue: kAudioObjectUnknown
        )
        guard deviceID != kAudioObjectUnknown else {
            throw DefaultAudioRouteError.unresolvedDevice(uid: uid)
        }
        return deviceID
    }

    private func setAndVerify(
        _ selector: Selector,
        deviceID: AudioObjectID,
        expectedUID: String
    ) throws {
        try writer.writeValue(
            deviceID,
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: HALPropertyAddress(selector: selector.property),
            operation: "Set default \(selector.name) device"
        )
        let actualUID = try currentUID(selector)
        guard actualUID == expectedUID else {
            throw DefaultAudioRouteError.verificationFailed(
                selector: selector.name,
                expectedUID: expectedUID,
                actualUID: actualUID
            )
        }
    }
}
