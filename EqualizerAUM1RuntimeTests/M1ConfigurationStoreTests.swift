import Foundation
import XCTest

final class M1ConfigurationStoreTests: XCTestCase {
    func testFirstLaunchEstablishesPreviousBeforeMain() async throws {
        let fileSystem = FakeM1ConfigurationFileSystem()
        let store = M1ConfigurationStore(fileSystem: fileSystem)
        let nodeID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

        let result = await store.bootstrap(initialNodeID: nodeID)

        XCTAssertEqual(result, .loaded(.initial(nodeID: nodeID)))
        XCTAssertEqual(
            fileSystem.events,
            ["prepare", "cleanup", "read:config.json", "read:config.previous.json", "prepare", "write:1", "write:2", "replace:config.previous.json", "sync:1", "replace:config.json", "sync:2"]
        )
        XCTAssertEqual(fileSystem.files["config.json"], fileSystem.files["config.previous.json"])
    }

    func testSaveRotatesCompleteMainBeforeInstallingCandidate() async throws {
        let old = try encoded(gainDB: -3)
        let next = try encoded(gainDB: -6)
        let fileSystem = FakeM1ConfigurationFileSystem(files: ["config.json": old.data])
        let store = M1ConfigurationStore(fileSystem: fileSystem)

        let result = await store.commit(next, generation: 1, mode: .save)

        XCTAssertEqual(result, .succeeded(generation: 1, snapshot: next.snapshot))
        XCTAssertEqual(fileSystem.files["config.previous.json"], old.data)
        XCTAssertEqual(fileSystem.files["config.json"], next.data)
        XCTAssertEqual(
            Array(fileSystem.events.suffix(6)),
            ["write:1", "write:2", "replace:config.previous.json", "sync:1", "replace:config.json", "sync:2"]
        )
    }

    func testFailureBeforeMainReplacementLeavesOldMainAndDefiniteFailure() async throws {
        let old = try encoded(gainDB: -3)
        let next = try encoded(gainDB: -6)
        let fileSystem = FakeM1ConfigurationFileSystem(files: ["config.json": old.data])
        fileSystem.failures = ["replace:config.json"]
        let store = M1ConfigurationStore(fileSystem: fileSystem)

        let result = await store.commit(next, generation: 1, mode: .save)

        XCTAssertEqual(result, .failed(generation: 1, reason: .replaceMain))
        XCTAssertEqual(fileSystem.files["config.json"], old.data)
        XCTAssertEqual(fileSystem.files["config.previous.json"], old.data)
    }

    func testFinalDirectorySyncFailureIsUncertainAndRetriesOnlySameGeneration() async throws {
        let old = try encoded(gainDB: -3)
        let next = try encoded(gainDB: -6)
        let fileSystem = FakeM1ConfigurationFileSystem(files: ["config.json": old.data])
        fileSystem.failures = ["sync:2", "sync:3"]
        let store = M1ConfigurationStore(fileSystem: fileSystem)

        let result = await store.commit(next, generation: 7, mode: .save)
        let wrongRetry = await store.retryUncertain(generation: 8)
        let failedRetry = await store.retryUncertain(generation: 7)
        let successfulRetry = await store.retryUncertain(generation: 7)

        XCTAssertEqual(
            result,
            .uncertain(generation: 7, snapshot: next.snapshot, bootstrapOrigin: nil)
        )
        XCTAssertEqual(wrongRetry, .failed(generation: 8, reason: .persistenceRestricted))
        XCTAssertEqual(
            failedRetry,
            .uncertain(generation: 7, snapshot: next.snapshot, bootstrapOrigin: nil)
        )
        XCTAssertEqual(successfulRetry, .succeeded(generation: 7, snapshot: next.snapshot))
        XCTAssertEqual(fileSystem.events.filter { $0.hasPrefix("write:") }.count, 2)
        XCTAssertEqual(fileSystem.files["config.json"], next.data)
    }

    func testUncertainStateRejectsNewCandidateAndGenerationCannotBeReused() async throws {
        let old = try encoded(gainDB: -3)
        let first = try encoded(gainDB: -6)
        let second = try encoded(gainDB: -9)
        let fileSystem = FakeM1ConfigurationFileSystem(files: ["config.json": old.data])
        fileSystem.failures = ["sync:2"]
        let store = M1ConfigurationStore(fileSystem: fileSystem)

        _ = await store.commit(first, generation: 1, mode: .save)
        let blocked = await store.commit(second, generation: 2, mode: .save)
        _ = await store.retryUncertain(generation: 1)
        let reused = await store.commit(second, generation: 1, mode: .save)

        XCTAssertEqual(blocked, .failed(generation: 2, reason: .persistenceRestricted))
        XCTAssertEqual(reused, .failed(generation: 1, reason: .generationNotIncreasing))
    }

    func testBootstrapUncertaintyExposesRetryGeneration() async {
        let fileSystem = FakeM1ConfigurationFileSystem()
        fileSystem.failures = ["sync:2", "sync:3"]
        let store = M1ConfigurationStore(fileSystem: fileSystem)
        let nodeID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

        let bootstrap = await store.bootstrap(initialNodeID: nodeID)
        let failedRetry = await store.retryUncertain(generation: 0)
        let retry = await store.retryUncertain(generation: 0)

        XCTAssertEqual(
            bootstrap,
            .uncertain(
                generation: 0,
                snapshot: .initial(nodeID: nodeID),
                origin: .initialConfiguration
            )
        )
        XCTAssertEqual(
            failedRetry,
            .uncertain(
                generation: 0,
                snapshot: .initial(nodeID: nodeID),
                bootstrapOrigin: .initialConfiguration
            )
        )
        XCTAssertEqual(
            retry,
            .succeeded(generation: 0, snapshot: .initial(nodeID: nodeID))
        )
        XCTAssertEqual(fileSystem.events.filter { $0.hasPrefix("write:") }.count, 2)
    }

    func testSaveDistinguishesMainReadFailureFromInvalidMain() async throws {
        let next = try encoded(gainDB: -6)

        let unreadable = FakeM1ConfigurationFileSystem()
        unreadable.failures = ["read:config.json"]
        let readFailure = await M1ConfigurationStore(fileSystem: unreadable)
            .commit(next, generation: 1, mode: .save)

        let invalid = FakeM1ConfigurationFileSystem(files: ["config.json": Data("invalid".utf8)])
        let invalidFailure = await M1ConfigurationStore(fileSystem: invalid)
            .commit(next, generation: 1, mode: .save)

        let oversized = FakeM1ConfigurationFileSystem(
            files: ["config.json": Data(count: M1ConfigurationCodec.maximumDataSize + 1)]
        )
        let oversizedFailure = await M1ConfigurationStore(fileSystem: oversized)
            .commit(next, generation: 1, mode: .save)

        XCTAssertEqual(readFailure, .failed(generation: 1, reason: .readCurrentMain))
        XCTAssertEqual(invalidFailure, .failed(generation: 1, reason: .invalidCurrentMain))
        XCTAssertEqual(oversizedFailure, .failed(generation: 1, reason: .invalidCurrentMain))
        XCTAssertFalse(unreadable.events.contains { $0.hasPrefix("write:") })
        XCTAssertFalse(invalid.events.contains { $0.hasPrefix("write:") })
        XCTAssertFalse(oversized.events.contains { $0.hasPrefix("write:") })
    }

    func testBootstrapDistinguishesMainAndPreviousReadFailures() async {
        let mainFailure = FakeM1ConfigurationFileSystem()
        mainFailure.failures = ["read:config.json"]
        let mainResult = await M1ConfigurationStore(fileSystem: mainFailure).bootstrap()

        let previousFailure = FakeM1ConfigurationFileSystem(
            files: ["config.json": Data("invalid".utf8)]
        )
        previousFailure.failures = ["read:config.previous.json"]
        let previousResult = await M1ConfigurationStore(fileSystem: previousFailure)
            .bootstrap()

        XCTAssertEqual(
            mainResult,
            .recovery(
                editable: .transparentRecovery,
                runtime: .transparentRecovery,
                reason: .mainReadFailedAndPreviousUnavailable
            )
        )
        XCTAssertEqual(
            previousResult,
            .recovery(
                editable: .transparentRecovery,
                runtime: .transparentRecovery,
                reason: .previousReadFailedAfterMainUnavailable
            )
        )
    }

    func testEveryPreMainFailureIsDefiniteAndRemovesTemporaryFiles() async throws {
        let old = try encoded(gainDB: -3)
        let next = try encoded(gainDB: -6)
        let cases: [(String, M1ConfigurationCommitFailure)] = [
            ("write:1", .writeNext),
            ("write:2", .writePrevious),
            ("replace:config.previous.json", .replacePrevious),
            ("sync:1", .synchronizePrevious),
            ("replace:config.json", .replaceMain)
        ]

        for (failure, expectedReason) in cases {
            let fileSystem = FakeM1ConfigurationFileSystem(files: ["config.json": old.data])
            fileSystem.failures = [failure]
            let store = M1ConfigurationStore(fileSystem: fileSystem)

            let result = await store.commit(next, generation: 1, mode: .save)

            XCTAssertEqual(result, .failed(generation: 1, reason: expectedReason), failure)
            XCTAssertEqual(fileSystem.files["config.json"], old.data, failure)
            XCTAssertEqual(fileSystem.temporaryFileCount, 0, failure)
        }
    }

    func testPreviousRecoveryRebuildsMainWithoutReplacingPrevious() async throws {
        let previous = try encoded(gainDB: -12)
        let fileSystem = FakeM1ConfigurationFileSystem(
            files: ["config.json": Data("invalid".utf8), "config.previous.json": previous.data]
        )
        let store = M1ConfigurationStore(fileSystem: fileSystem)

        let result = await store.bootstrap()

        XCTAssertEqual(result, .recoveredFromPrevious(previous.snapshot))
        XCTAssertEqual(fileSystem.files["config.json"], previous.data)
        XCTAssertEqual(fileSystem.files["config.previous.json"], previous.data)
        XCTAssertFalse(fileSystem.events.contains("replace:config.previous.json"))
    }

    func testPreviousRecoveryFinalSyncFailureIsRetryableGenerationZero() async throws {
        let previous = try encoded(gainDB: -9)
        let fileSystem = FakeM1ConfigurationFileSystem(
            files: ["config.previous.json": previous.data]
        )
        fileSystem.failures = ["sync:1", "sync:2"]
        let store = M1ConfigurationStore(fileSystem: fileSystem)

        let result = await store.bootstrap()
        let writesBeforeRetry = fileSystem.events.filter { $0.hasPrefix("write:") }.count
        let failedRetry = await store.retryUncertain(generation: 0)
        let retry = await store.retryUncertain(generation: 0)

        XCTAssertEqual(
            result,
            .uncertain(
                generation: 0,
                snapshot: previous.snapshot,
                origin: .previousRecovery
            )
        )
        XCTAssertEqual(
            failedRetry,
            .uncertain(
                generation: 0,
                snapshot: previous.snapshot,
                bootstrapOrigin: .previousRecovery
            )
        )
        XCTAssertEqual(retry, .succeeded(generation: 0, snapshot: previous.snapshot))
        XCTAssertEqual(fileSystem.files["config.previous.json"], previous.data)
        XCTAssertEqual(fileSystem.files["config.json"], previous.data)
        XCTAssertEqual(
            fileSystem.events.filter { $0.hasPrefix("write:") }.count,
            writesBeforeRetry
        )
    }

    func testPreviousRecoveryFailureKeepsRecoverySnapshotAndSolePrevious() async throws {
        let previous = try encoded(gainDB: -12)
        let invalidMain = Data("invalid".utf8)
        let fileSystem = FakeM1ConfigurationFileSystem(
            files: ["config.json": invalidMain, "config.previous.json": previous.data]
        )
        fileSystem.failures = ["replace:config.json"]
        let store = M1ConfigurationStore(fileSystem: fileSystem)

        let result = await store.bootstrap()

        XCTAssertEqual(
            result,
            .recovery(
                editable: previous.snapshot,
                runtime: previous.snapshot,
                reason: .previousRecoveredButMainRebuildFailed
            )
        )
        XCTAssertEqual(fileSystem.files["config.json"], invalidMain)
        XCTAssertEqual(fileSystem.files["config.previous.json"], previous.data)
    }

    func testDualCorruptionUsesTransparentRecoveryAndRepairEstablishesBothFiles() async throws {
        let fileSystem = FakeM1ConfigurationFileSystem(
            files: [
                "config.json": Data("invalid-main".utf8),
                "config.previous.json": Data("invalid-previous".utf8)
            ]
        )
        let store = M1ConfigurationStore(fileSystem: fileSystem)

        let bootstrap = await store.bootstrap()
        let repair = try encoded(gainDB: -4)
        let commit = await store.commit(repair, generation: 1, mode: .repair)

        XCTAssertEqual(
            bootstrap,
            .recovery(
                editable: .transparentRecovery,
                runtime: .transparentRecovery,
                reason: .mainInvalidAndPreviousUnavailable
            )
        )
        XCTAssertEqual(commit, .succeeded(generation: 1, snapshot: repair.snapshot))
        XCTAssertEqual(fileSystem.files["config.previous.json"], repair.data)
        XCTAssertEqual(fileSystem.files["config.json"], repair.data)
    }

    func testRepairFinalSyncFailureIsUncertainAndRetriesWithoutRewriting() async throws {
        let repair = try encoded(gainDB: -4)
        let fileSystem = FakeM1ConfigurationFileSystem(
            files: [
                "config.json": Data("invalid-main".utf8),
                "config.previous.json": Data("invalid-previous".utf8)
            ]
        )
        fileSystem.failures = ["sync:2", "sync:3"]
        let store = M1ConfigurationStore(fileSystem: fileSystem)

        let result = await store.commit(repair, generation: 4, mode: .repair)
        let writesBeforeRetry = fileSystem.events.filter { $0.hasPrefix("write:") }.count
        let failedRetry = await store.retryUncertain(generation: 4)
        let successfulRetry = await store.retryUncertain(generation: 4)

        XCTAssertEqual(
            result,
            .uncertain(generation: 4, snapshot: repair.snapshot, bootstrapOrigin: nil)
        )
        XCTAssertEqual(
            failedRetry,
            .uncertain(generation: 4, snapshot: repair.snapshot, bootstrapOrigin: nil)
        )
        XCTAssertEqual(successfulRetry, .succeeded(generation: 4, snapshot: repair.snapshot))
        XCTAssertEqual(fileSystem.files["config.previous.json"], repair.data)
        XCTAssertEqual(fileSystem.files["config.json"], repair.data)
        XCTAssertEqual(
            fileSystem.events.filter { $0.hasPrefix("write:") }.count,
            writesBeforeRetry
        )
    }

    func testOversizedMainFallsBackToPreviousWithoutAllocatingIt() async throws {
        let previous = try encoded(gainDB: -8)
        let fileSystem = FakeM1ConfigurationFileSystem(
            files: [
                "config.json": Data(count: M1ConfigurationCodec.maximumDataSize + 1),
                "config.previous.json": previous.data
            ]
        )
        let store = M1ConfigurationStore(fileSystem: fileSystem)

        let result = await store.bootstrap()

        XCTAssertEqual(result, .recoveredFromPrevious(previous.snapshot))
        XCTAssertEqual(fileSystem.files["config.json"], previous.data)
    }

    func testBootstrapDirectoryPreparationFailureUsesEditableSafeRecovery() async {
        let fileSystem = FakeM1ConfigurationFileSystem()
        fileSystem.failures = ["prepare"]
        let nodeID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

        let result = await M1ConfigurationStore(fileSystem: fileSystem)
            .bootstrap(initialNodeID: nodeID)

        XCTAssertEqual(
            result,
            .recovery(
                editable: .initial(nodeID: nodeID),
                runtime: .transparentRecovery,
                reason: .initialConfigurationWriteFailed
            )
        )
    }

    func testInitialWriteFailureUsesEditableDefaultButTransparentRuntime() async {
        let fileSystem = FakeM1ConfigurationFileSystem()
        fileSystem.failures = ["write:1"]
        let store = M1ConfigurationStore(fileSystem: fileSystem)
        let nodeID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

        let result = await store.bootstrap(initialNodeID: nodeID)

        XCTAssertEqual(
            result,
            .recovery(
                editable: .initial(nodeID: nodeID),
                runtime: .transparentRecovery,
                reason: .initialConfigurationWriteFailed
            )
        )
        XCTAssertNil(fileSystem.files["config.json"])
    }

    func testApplicationSupportStoreCanBeConstructedWithoutIO() {
        _ = M1ConfigurationStore.applicationSupportStore()
    }

    func testPOSIXStoreCreatesDurableCanonicalFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("M1ConfigurationStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = M1ConfigurationStore(
            fileSystem: M1POSIXConfigurationFileSystem(directoryURL: directory)
        )
        let nodeID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

        let result = await store.bootstrap(initialNodeID: nodeID)

        XCTAssertEqual(result, .loaded(.initial(nodeID: nodeID)))
        let main = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        let previous = try Data(contentsOf: directory.appendingPathComponent("config.previous.json"))
        XCTAssertEqual(main, previous)
        XCTAssertEqual(try M1ConfigurationCodec.decode(main).snapshot, .initial(nodeID: nodeID))
    }

    func testPOSIXBootstrapRemovesOnlyAbandonedConfigurationTemporaries() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("M1ConfigurationStoreCleanupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let abandoned = directory.appendingPathComponent(".config.abandoned.tmp")
        let unrelated = directory.appendingPathComponent("unrelated.tmp")
        try Data("abandoned".utf8).write(to: abandoned)
        try Data("keep".utf8).write(to: unrelated)
        let store = M1ConfigurationStore(
            fileSystem: M1POSIXConfigurationFileSystem(directoryURL: directory)
        )

        _ = await store.bootstrap()

        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testPOSIXFileSystemMapsMissingDirectoryAndInvalidFileOperations() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("M1POSIXConfigurationFailureTests-\(UUID().uuidString)")
        let fileSystem = M1POSIXConfigurationFileSystem(directoryURL: directory)

        XCTAssertThrowsError(try fileSystem.cleanupTemporaryFiles()) {
            XCTAssertEqual($0 as? M1ConfigurationStoreIOError, .cleanupTemporaryFiles)
        }
        XCTAssertThrowsError(try fileSystem.writeTemporaryFile(Data("x".utf8))) {
            XCTAssertEqual($0 as? M1ConfigurationStoreIOError, .writeTemporaryFile)
        }
        XCTAssertThrowsError(
            try fileSystem.replaceFile(named: "config.json", withTemporaryFileNamed: "missing.tmp")
        ) {
            XCTAssertEqual($0 as? M1ConfigurationStoreIOError, .replaceFile)
        }
        XCTAssertThrowsError(try fileSystem.synchronizeDirectory()) {
            XCTAssertEqual($0 as? M1ConfigurationStoreIOError, .synchronizeDirectory)
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("directory.json"),
            withIntermediateDirectories: false
        )
        XCTAssertThrowsError(
            try fileSystem.readFile(named: "directory.json", maximumSize: 8)
        ) {
            XCTAssertEqual($0 as? M1ConfigurationStoreIOError, .readFile)
        }
    }

    func testPOSIXFileSystemReadsBoundsReplacesSynchronizesAndRemovesFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("M1POSIXConfigurationFileSystemTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileSystem = M1POSIXConfigurationFileSystem(directoryURL: directory)
        try fileSystem.prepareDirectory()

        XCTAssertNil(try fileSystem.readFile(named: "missing.json", maximumSize: 8))
        let temporaryName = try fileSystem.writeTemporaryFile(Data("payload".utf8))
        try fileSystem.replaceFile(named: "config.json", withTemporaryFileNamed: temporaryName)
        try fileSystem.synchronizeDirectory()
        XCTAssertEqual(
            try fileSystem.readFile(named: "config.json", maximumSize: 7),
            Data("payload".utf8)
        )
        XCTAssertThrowsError(try fileSystem.readFile(named: "config.json", maximumSize: 6)) {
            XCTAssertEqual($0 as? M1ConfigurationStoreIOError, .fileTooLarge)
        }
        fileSystem.removeFileIfPresent(named: "config.json")
        XCTAssertNil(try fileSystem.readFile(named: "config.json", maximumSize: 7))
    }

    private func encoded(gainDB: Double) throws -> M1EncodedConfiguration {
        try M1ConfigurationCodec.encode(
            M1ConfigurationSnapshot(
                effectsEnabled: true,
                nodes: [
                    M1PreampNode(
                        id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
                        isEnabled: true,
                        gainDB: gainDB,
                        channels: .all
                    )
                ]
            )
        )
    }
}

private final class FakeM1ConfigurationFileSystem: M1ConfigurationFileSystem, @unchecked Sendable {
    var files: [String: Data]
    var failures: Set<String> = []
    private(set) var events: [String] = []
    var temporaryFileCount: Int { temporaryFiles.count }
    private var temporaryFiles: [String: Data] = [:]
    private var writeCount = 0
    private var syncCount = 0

    init(files: [String: Data] = [:]) {
        self.files = files
    }

    func prepareDirectory() throws {
        try record("prepare")
    }

    func cleanupTemporaryFiles() throws {
        try record("cleanup")
    }

    func readFile(named name: String, maximumSize: Int) throws -> Data? {
        try record("read:\(name)")
        guard let data = files[name] else {
            return nil
        }
        guard data.count <= maximumSize else {
            throw M1ConfigurationStoreIOError.fileTooLarge
        }
        return data
    }

    func writeTemporaryFile(_ data: Data) throws -> String {
        writeCount += 1
        try record("write:\(writeCount)")
        let name = "temp-\(writeCount)"
        temporaryFiles[name] = data
        return name
    }

    func replaceFile(named name: String, withTemporaryFileNamed temporaryName: String) throws {
        try record("replace:\(name)")
        guard let data = temporaryFiles.removeValue(forKey: temporaryName) else {
            throw M1ConfigurationStoreIOError.replaceFile
        }
        files[name] = data
    }

    func synchronizeDirectory() throws {
        syncCount += 1
        try record("sync:\(syncCount)")
    }

    func removeFileIfPresent(named name: String) {
        events.append("remove:\(name)")
        temporaryFiles.removeValue(forKey: name)
    }

    private func record(_ event: String) throws {
        events.append(event)
        if failures.remove(event) != nil {
            throw M1ConfigurationStoreIOError.writeTemporaryFile
        }
    }
}
