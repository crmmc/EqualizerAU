import CoreAudio
import XCTest
@testable import EqualizerAU

final class DefaultAudioRouteControllerTests: XCTestCase {
    func testActivationPersistsBeforeSwitchAndRestoreReturnsBothSelectors() async throws {
        let hal = RouteHALStub()
        let journal = MemoryRouteJournalStore()
        let controller = DefaultAudioRouteController(operations: hal, journalStore: journal)

        let resource = try await controller.activate(
            virtualDevice: blackHoleFixture(),
            generation: AudioGeneration(rawValue: 10)
        )

        XCTAssertEqual(hal.defaults, [700, 700])
        let activeJournal = await journal.value
        XCTAssertEqual(activeJournal, resource.journal)

        try await controller.restore(resource)

        XCTAssertEqual(hal.defaults, [100, 101])
        let clearedJournal = await journal.value
        XCTAssertNil(clearedJournal)
    }

    func testRestoreDoesNotOverrideUserDeviceChange() async throws {
        let hal = RouteHALStub()
        let journal = MemoryRouteJournalStore()
        let controller = DefaultAudioRouteController(operations: hal, journalStore: journal)
        let resource = try await controller.activate(
            virtualDevice: blackHoleFixture(),
            generation: AudioGeneration(rawValue: 11)
        )
        hal.userSelectsOutput(900)

        try await controller.restore(resource)

        XCTAssertEqual(hal.defaults, [900, 101])
        let clearedJournal = await journal.value
        XCTAssertNil(clearedJournal)
    }

    func testActivationFailureRollsBackChangedSelectorAndClearsJournal() async {
        let hal = RouteHALStub(failingSetSelector: kAudioHardwarePropertyDefaultSystemOutputDevice)
        let journal = MemoryRouteJournalStore()
        let controller = DefaultAudioRouteController(operations: hal, journalStore: journal)

        do {
            _ = try await controller.activate(
                virtualDevice: blackHoleFixture(),
                generation: AudioGeneration(rawValue: 12)
            )
            XCTFail("Expected route activation failure")
        } catch {
            XCTAssertEqual(hal.defaults, [100, 101])
            let clearedJournal = await journal.value
            XCTAssertNil(clearedJournal)
        }
    }

    func testRecoveryJournalRestoresOnlyOwnedVirtualSelectors() async throws {
        let hal = RouteHALStub(defaultOutput: 700, defaultSystemOutput: 700)
        let journal = MemoryRouteJournalStore(value: DefaultAudioRouteJournal(
            virtualDeviceUID: BlackHoleDeviceSnapshot.expectedUID,
            originalOutputDeviceUID: "physical-output",
            originalSystemOutputDeviceUID: "physical-system"
        ))
        let controller = DefaultAudioRouteController(operations: hal, journalStore: journal)

        try await controller.recoverIfNeeded()

        XCTAssertEqual(hal.defaults, [100, 101])
        let clearedJournal = await journal.value
        XCTAssertNil(clearedJournal)
    }
}

private actor MemoryRouteJournalStore: AudioRouteJournalStoring {
    private(set) var value: DefaultAudioRouteJournal?

    init(value: DefaultAudioRouteJournal? = nil) {
        self.value = value
    }

    func load() -> DefaultAudioRouteJournal? { value }
    func save(_ journal: DefaultAudioRouteJournal) { value = journal }
    func clear() { value = nil }
}

private final class RouteHALStub: @unchecked Sendable, HALPropertyOperations {
    private let lock = NSLock()
    private var defaultOutput: AudioObjectID
    private var defaultSystemOutput: AudioObjectID
    private let failingSetSelector: AudioObjectPropertySelector?
    private let uidByID: [AudioObjectID: String] = [
        100: "physical-output",
        101: "physical-system",
        700: BlackHoleDeviceSnapshot.expectedUID,
        900: "user-selected-output"
    ]

    init(
        defaultOutput: AudioObjectID = 100,
        defaultSystemOutput: AudioObjectID = 101,
        failingSetSelector: AudioObjectPropertySelector? = nil
    ) {
        self.defaultOutput = defaultOutput
        self.defaultSystemOutput = defaultSystemOutput
        self.failingSetSelector = failingSetSelector
    }

    var defaults: [AudioObjectID] {
        lock.withLock { [defaultOutput, defaultSystemOutput] }
    }

    func userSelectsOutput(_ deviceID: AudioObjectID) {
        lock.withLock { defaultOutput = deviceID }
    }

    func propertyDataSize(
        objectID: AudioObjectID,
        address: HALPropertyAddress
    ) -> (status: OSStatus, size: UInt32) {
        (noErr, 0)
    }

    func propertyData(
        objectID: AudioObjectID,
        address: HALPropertyAddress,
        dataSize: inout UInt32,
        data: UnsafeMutableRawPointer
    ) -> OSStatus {
        if objectID == AudioObjectID(kAudioObjectSystemObject) {
            let value: AudioObjectID = lock.withLock {
                address.selector == kAudioHardwarePropertyDefaultOutputDevice
                    ? defaultOutput : defaultSystemOutput
            }
            return write(value, dataSize: &dataSize, data: data)
        }
        guard address.selector == kAudioDevicePropertyDeviceUID,
              let uid = uidByID[objectID] else { return kAudioHardwareBadObjectError }
        let retained = Unmanaged.passRetained(uid as CFString)
        return write(Optional(retained), dataSize: &dataSize, data: data)
    }

    func qualifiedPropertyData(
        objectID: AudioObjectID,
        address: HALPropertyAddress,
        qualifierDataSize: UInt32,
        qualifierData: UnsafeRawPointer,
        dataSize: inout UInt32,
        data: UnsafeMutableRawPointer
    ) -> OSStatus {
        guard address.selector == kAudioHardwarePropertyTranslateUIDToDevice else {
            return kAudio_ParamError
        }
        let uid = qualifierData.assumingMemoryBound(to: CFString.self).pointee as String
        let resolved = uidByID.first(where: { $0.value == uid })?.key ?? kAudioObjectUnknown
        return write(resolved, dataSize: &dataSize, data: data)
    }

    func setPropertyData(
        objectID: AudioObjectID,
        address: HALPropertyAddress,
        dataSize: UInt32,
        data: UnsafeRawPointer
    ) -> OSStatus {
        guard objectID == AudioObjectID(kAudioObjectSystemObject) else {
            return kAudioHardwareBadObjectError
        }
        if address.selector == failingSetSelector { return kAudioHardwareUnsupportedOperationError }
        let deviceID = data.load(as: AudioObjectID.self)
        lock.withLock {
            if address.selector == kAudioHardwarePropertyDefaultOutputDevice {
                defaultOutput = deviceID
            } else if address.selector == kAudioHardwarePropertyDefaultSystemOutputDevice {
                defaultSystemOutput = deviceID
            }
        }
        return noErr
    }

    private func write<Value>(
        _ value: Value,
        dataSize: inout UInt32,
        data: UnsafeMutableRawPointer
    ) -> OSStatus {
        data.assumingMemoryBound(to: Value.self).pointee = value
        dataSize = UInt32(MemoryLayout<Value>.size)
        return noErr
    }
}

private func blackHoleFixture() -> BlackHoleDeviceSnapshot {
    let layout = AudioBufferLayout(buffers: [.init(index: 0, channelCount: 2)])
    let format = AudioStreamBasicDescription(
        mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
        mBytesPerPacket: 8,
        mFramesPerPacket: 1,
        mBytesPerFrame: 8,
        mChannelsPerFrame: 2,
        mBitsPerChannel: 32,
        mReserved: 0
    )
    return BlackHoleDeviceSnapshot(
        generation: AudioGeneration(rawValue: 10),
        objectID: 700,
        uid: BlackHoleDeviceSnapshot.expectedUID,
        modelUID: BlackHoleDeviceSnapshot.expectedModelUID,
        name: BlackHoleDeviceSnapshot.expectedName,
        manufacturer: BlackHoleDeviceSnapshot.expectedManufacturer,
        transportType: kAudioDeviceTransportTypeVirtual,
        isAlive: true,
        isHidden: false,
        nominalSampleRate: 48_000,
        clockDomain: 0,
        inputLayout: layout,
        outputLayout: layout,
        inputFormat: format,
        outputFormat: format
    )
}
