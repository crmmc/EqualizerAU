import Darwin
import Foundation

protocol M1ConfigurationFileSystem: Sendable {
    func prepareDirectory() throws
    func cleanupTemporaryFiles() throws
    func readFile(named name: String, maximumSize: Int) throws -> Data?
    func writeTemporaryFile(_ data: Data) throws -> String
    func replaceFile(named name: String, withTemporaryFileNamed temporaryName: String) throws
    func synchronizeDirectory() throws
    func removeFileIfPresent(named name: String)
}

struct M1POSIXConfigurationFileSystem: M1ConfigurationFileSystem, Sendable {
    let directoryURL: URL

    func prepareDirectory() throws {
        var directoryInfo = stat()
        let directoryExisted = lstat(directoryURL.path, &directoryInfo) == 0
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            if !directoryExisted {
                try synchronizeDirectory(at: directoryURL.deletingLastPathComponent())
            }
        } catch {
            throw M1ConfigurationStoreIOError.prepareDirectory
        }
    }

    func cleanupTemporaryFiles() throws {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
        } catch {
            throw M1ConfigurationStoreIOError.cleanupTemporaryFiles
        }
        for name in names where name.hasPrefix(".config.") && name.hasSuffix(".tmp") {
            let result = unlink(directoryURL.appendingPathComponent(name).path)
            guard result == 0 || errno == ENOENT else {
                throw M1ConfigurationStoreIOError.cleanupTemporaryFiles
            }
        }
    }

    func readFile(named name: String, maximumSize: Int) throws -> Data? {
        let path = directoryURL.appendingPathComponent(name).path
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT {
                return nil
            }
            throw M1ConfigurationStoreIOError.readFile
        }
        defer { close(descriptor) }

        var data = Data(count: maximumSize + 1)
        let readCount = data.withUnsafeMutableBytes { bytes -> Int? in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            var offset = 0
            while true {
                guard offset < bytes.count else { return offset }
                let count = read(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR {
                    continue
                }
                guard count >= 0 else { return nil }
                guard count > 0 else { return offset }
                offset += count
            }
        }
        guard let readCount else {
            throw M1ConfigurationStoreIOError.readFile
        }
        guard readCount <= maximumSize else {
            throw M1ConfigurationStoreIOError.fileTooLarge
        }
        data.removeSubrange(readCount..<data.count)
        return data
    }

    func writeTemporaryFile(_ data: Data) throws -> String {
        let name = ".config.\(UUID().uuidString).tmp"
        let path = directoryURL.appendingPathComponent(name).path
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw M1ConfigurationStoreIOError.writeTemporaryFile
        }

        var descriptorIsOpen = true
        var succeeded = false
        defer {
            if descriptorIsOpen {
                close(descriptor)
            }
            if !succeeded {
                unlink(path)
            }
        }
        let didWriteAll = data.withUnsafeBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else {
                return true
            }
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    return false
                }
                offset += count
            }
            return true
        }
        guard didWriteAll, fsync(descriptor) == 0 else {
            throw M1ConfigurationStoreIOError.writeTemporaryFile
        }
        let closeResult = close(descriptor)
        descriptorIsOpen = false
        guard closeResult == 0 else {
            throw M1ConfigurationStoreIOError.writeTemporaryFile
        }
        succeeded = true
        return name
    }

    func replaceFile(named name: String, withTemporaryFileNamed temporaryName: String) throws {
        let source = directoryURL.appendingPathComponent(temporaryName).path
        let destination = directoryURL.appendingPathComponent(name).path
        guard rename(source, destination) == 0 else {
            throw M1ConfigurationStoreIOError.replaceFile
        }
    }

    func synchronizeDirectory() throws {
        try synchronizeDirectory(at: directoryURL)
    }

    private func synchronizeDirectory(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw M1ConfigurationStoreIOError.synchronizeDirectory
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw M1ConfigurationStoreIOError.synchronizeDirectory
        }
    }

    func removeFileIfPresent(named name: String) {
        unlink(directoryURL.appendingPathComponent(name).path)
    }
}

enum M1ConfigurationStoreIOError: Error, Equatable, Sendable {
    case prepareDirectory
    case cleanupTemporaryFiles
    case readFile
    case fileTooLarge
    case writeTemporaryFile
    case replaceFile
    case synchronizeDirectory
}

enum M1ConfigurationCommitMode: Sendable {
    case save
    case repair
}

enum M1ConfigurationCommitFailure: Error, Equatable, Sendable {
    case generationNotIncreasing
    case persistenceRestricted
    case invalidCurrentMain
    case prepareDirectory
    case readCurrentMain
    case writeNext
    case writePrevious
    case replacePrevious
    case synchronizePrevious
    case replaceMain
}

enum M1ConfigurationBootstrapUncertainOrigin: Equatable, Sendable {
    case initialConfiguration
    case previousRecovery
}

enum M1ConfigurationCommitResult: Equatable, Sendable {
    case succeeded(generation: UInt64, snapshot: M1ConfigurationSnapshot)
    case failed(generation: UInt64, reason: M1ConfigurationCommitFailure)
    case uncertain(
        generation: UInt64,
        snapshot: M1ConfigurationSnapshot,
        bootstrapOrigin: M1ConfigurationBootstrapUncertainOrigin?
    )
}

enum M1ConfigurationRecoveryReason: Equatable, Sendable {
    case mainInvalidAndPreviousUnavailable
    case mainReadFailedAndPreviousUnavailable
    case previousReadFailedAfterMainUnavailable
    case previousRecoveredButMainRebuildFailed
    case initialConfigurationWriteFailed
}

enum M1ConfigurationBootstrapResult: Equatable, Sendable {
    case loaded(M1ConfigurationSnapshot)
    case recoveredFromPrevious(M1ConfigurationSnapshot)
    case recovery(
        editable: M1ConfigurationSnapshot,
        runtime: M1ConfigurationSnapshot,
        reason: M1ConfigurationRecoveryReason
    )
    case uncertain(
        generation: UInt64,
        snapshot: M1ConfigurationSnapshot,
        origin: M1ConfigurationBootstrapUncertainOrigin
    )
}

actor M1ConfigurationStore {
    static let mainFileName = "config.json"
    static let previousFileName = "config.previous.json"

    private let fileSystem: any M1ConfigurationFileSystem
    private var lastAcceptedGeneration: UInt64?
    private var uncertainCommit: M1EncodedConfiguration?
    private var uncertainGeneration: UInt64?
    private var uncertainBootstrapOrigin: M1ConfigurationBootstrapUncertainOrigin?

    init(fileSystem: any M1ConfigurationFileSystem) {
        self.fileSystem = fileSystem
    }

    static func applicationSupportStore() -> M1ConfigurationStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return M1ConfigurationStore(
            fileSystem: M1POSIXConfigurationFileSystem(
                directoryURL: base.appendingPathComponent("EqualizerAU", isDirectory: true)
            )
        )
    }

    func bootstrap(initialNodeID: UUID = UUID()) -> M1ConfigurationBootstrapResult {
        do {
            try fileSystem.prepareDirectory()
        } catch {
            let initial = M1ConfigurationSnapshot.initial(nodeID: initialNodeID)
            return .recovery(
                editable: initial,
                runtime: .transparentRecovery,
                reason: .initialConfigurationWriteFailed
            )
        }
        try? fileSystem.cleanupTemporaryFiles()

        let mainResult = readConfiguration(named: Self.mainFileName)
        if case let .valid(main) = mainResult {
            return .loaded(main.snapshot)
        }

        let previousResult = readConfiguration(named: Self.previousFileName)
        if case let .valid(previous) = previousResult {
            switch rebuildMain(from: previous) {
            case .succeeded:
                return .recoveredFromPrevious(previous.snapshot)
            case .failed:
                return .recovery(
                    editable: previous.snapshot,
                    runtime: previous.snapshot,
                    reason: .previousRecoveredButMainRebuildFailed
                )
            case .uncertain:
                uncertainCommit = previous
                uncertainGeneration = 0
                uncertainBootstrapOrigin = .previousRecovery
                lastAcceptedGeneration = 0
                return .uncertain(
                    generation: 0,
                    snapshot: previous.snapshot,
                    origin: .previousRecovery
                )
            }
        }

        let bothMissing: Bool
        if case .missing = mainResult, case .missing = previousResult {
            bothMissing = true
        } else {
            bothMissing = false
        }
        guard bothMissing else {
            let reason: M1ConfigurationRecoveryReason
            switch (mainResult, previousResult) {
            case (.failed, _):
                reason = .mainReadFailedAndPreviousUnavailable
            case (_, .failed):
                reason = .previousReadFailedAfterMainUnavailable
            default:
                reason = .mainInvalidAndPreviousUnavailable
            }
            return .recovery(
                editable: .transparentRecovery,
                runtime: .transparentRecovery,
                reason: reason
            )
        }

        let initial = M1ConfigurationSnapshot.initial(nodeID: initialNodeID)
        guard let encoded = try? M1ConfigurationCodec.encode(initial) else {
            return .recovery(
                editable: initial,
                runtime: .transparentRecovery,
                reason: .initialConfigurationWriteFailed
            )
        }
        switch establish(encoded) {
        case .succeeded:
            return .loaded(initial)
        case .failed:
            return .recovery(
                editable: initial,
                runtime: .transparentRecovery,
                reason: .initialConfigurationWriteFailed
            )
        case .uncertain:
            uncertainCommit = encoded
            uncertainGeneration = 0
            uncertainBootstrapOrigin = .initialConfiguration
            lastAcceptedGeneration = 0
            return .uncertain(
                generation: 0,
                snapshot: initial,
                origin: .initialConfiguration
            )
        }
    }

    func commit(
        _ candidate: M1EncodedConfiguration,
        generation: UInt64,
        mode: M1ConfigurationCommitMode
    ) -> M1ConfigurationCommitResult {
        guard uncertainCommit == nil else {
            return .failed(generation: generation, reason: .persistenceRestricted)
        }
        if let lastAcceptedGeneration, generation <= lastAcceptedGeneration {
            return .failed(generation: generation, reason: .generationNotIncreasing)
        }
        lastAcceptedGeneration = generation

        let transaction: TransactionResult
        switch mode {
        case .save:
            switch readConfiguration(named: Self.mainFileName) {
            case let .valid(current):
                transaction = replace(candidate, preserving: current)
            case .missing, .invalid:
                return .failed(generation: generation, reason: .invalidCurrentMain)
            case .failed:
                return .failed(generation: generation, reason: .readCurrentMain)
            }
        case .repair:
            transaction = establish(candidate)
        }

        switch transaction {
        case .succeeded:
            return .succeeded(generation: generation, snapshot: candidate.snapshot)
        case let .failed(reason):
            return .failed(generation: generation, reason: reason)
        case .uncertain:
            uncertainCommit = candidate
            uncertainGeneration = generation
            uncertainBootstrapOrigin = nil
            return .uncertain(
                generation: generation,
                snapshot: candidate.snapshot,
                bootstrapOrigin: nil
            )
        }
    }

    func retryUncertain(generation: UInt64) -> M1ConfigurationCommitResult {
        guard let candidate = uncertainCommit,
              let expectedGeneration = uncertainGeneration,
              generation == expectedGeneration
        else {
            return .failed(generation: generation, reason: .persistenceRestricted)
        }
        do {
            try fileSystem.synchronizeDirectory()
            uncertainCommit = nil
            uncertainGeneration = nil
            uncertainBootstrapOrigin = nil
            return .succeeded(generation: generation, snapshot: candidate.snapshot)
        } catch {
            return .uncertain(
                generation: generation,
                snapshot: candidate.snapshot,
                bootstrapOrigin: uncertainBootstrapOrigin
            )
        }
    }

    private enum ConfigurationReadResult {
        case missing
        case invalid
        case valid(M1EncodedConfiguration)
        case failed
    }

    private func readConfiguration(named name: String) -> ConfigurationReadResult {
        let storedData: Data?
        do {
            storedData = try fileSystem.readFile(
                named: name,
                maximumSize: M1ConfigurationCodec.maximumDataSize
            )
        } catch M1ConfigurationStoreIOError.fileTooLarge {
            return .invalid
        } catch {
            return .failed
        }
        guard let data = storedData else {
            return .missing
        }
        do {
            return .valid(try M1ConfigurationCodec.decode(data))
        } catch {
            return .invalid
        }
    }

    private enum TransactionResult {
        case succeeded
        case failed(M1ConfigurationCommitFailure)
        case uncertain
    }

    private func establish(_ candidate: M1EncodedConfiguration) -> TransactionResult {
        commitFiles(candidate: candidate, previous: candidate)
    }

    private func replace(
        _ candidate: M1EncodedConfiguration,
        preserving current: M1EncodedConfiguration
    ) -> TransactionResult {
        commitFiles(candidate: candidate, previous: current)
    }

    private func commitFiles(
        candidate: M1EncodedConfiguration,
        previous: M1EncodedConfiguration
    ) -> TransactionResult {
        do {
            try fileSystem.prepareDirectory()
        } catch {
            return .failed(.prepareDirectory)
        }

        let nextName: String
        do {
            nextName = try fileSystem.writeTemporaryFile(candidate.data)
        } catch {
            return .failed(.writeNext)
        }
        var removeNext = true
        defer {
            if removeNext {
                fileSystem.removeFileIfPresent(named: nextName)
            }
        }

        let previousTemporaryName: String
        do {
            previousTemporaryName = try fileSystem.writeTemporaryFile(previous.data)
        } catch {
            return .failed(.writePrevious)
        }
        var removePrevious = true
        defer {
            if removePrevious {
                fileSystem.removeFileIfPresent(named: previousTemporaryName)
            }
        }

        do {
            try fileSystem.replaceFile(
                named: Self.previousFileName,
                withTemporaryFileNamed: previousTemporaryName
            )
            removePrevious = false
        } catch {
            return .failed(.replacePrevious)
        }
        do {
            try fileSystem.synchronizeDirectory()
        } catch {
            return .failed(.synchronizePrevious)
        }
        do {
            try fileSystem.replaceFile(named: Self.mainFileName, withTemporaryFileNamed: nextName)
            removeNext = false
        } catch {
            return .failed(.replaceMain)
        }
        do {
            try fileSystem.synchronizeDirectory()
            return .succeeded
        } catch {
            return .uncertain
        }
    }

    private func rebuildMain(from previous: M1EncodedConfiguration) -> TransactionResult {
        do {
            try fileSystem.prepareDirectory()
        } catch {
            return .failed(.prepareDirectory)
        }
        let nextName: String
        do {
            nextName = try fileSystem.writeTemporaryFile(previous.data)
        } catch {
            return .failed(.writeNext)
        }
        var removeNext = true
        defer {
            if removeNext {
                fileSystem.removeFileIfPresent(named: nextName)
            }
        }
        do {
            try fileSystem.replaceFile(named: Self.mainFileName, withTemporaryFileNamed: nextName)
            removeNext = false
        } catch {
            return .failed(.replaceMain)
        }
        do {
            try fileSystem.synchronizeDirectory()
            return .succeeded
        } catch {
            return .uncertain
        }
    }
}
