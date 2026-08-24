import CoreAudio
import Foundation
import XCTest

final class M1SystemAudioLifecycleMonitorTests: XCTestCase {
    func testStartIsIdempotentClassifiesDeviceEventsAndStopsAllListeners() throws {
        let operations = LifecycleOperationsFake(deviceID: 42, uids: [42: "output-a"])
        let monitor = M1SystemAudioLifecycleMonitor(operations: operations, timing: .immediate)
        let events = LockedLifecycleEvents()
        try monitor.start { events.append($0) }
        try monitor.start { events.append($0) }

        XCTAssertEqual(operations.addedSystemSelectors(), [
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDevices,
        ])
        XCTAssertEqual(Set(operations.addedDeviceSelectors()), Set(LifecycleOperationsFake.deviceSelectors))

        operations.triggerDevice(kAudioDevicePropertyNominalSampleRate)
        events.waitForCount(1)
        XCTAssertEqual(
            events.values(),
            [.outputFormatChanged(.init(objectID: 42, persistentUID: "output-a"))]
        )

        monitor.stop()
        monitor.stop()
        XCTAssertEqual(operations.removedSystemSelectors().count, 2)
        XCTAssertEqual(operations.removedDeviceSelectors().count, LifecycleOperationsFake.deviceSelectors.count)
    }

    func testDefaultAndDeviceListChangesRebindOnlyForChangedIdentity() throws {
        let operations = LifecycleOperationsFake(deviceID: 42, uids: [42: "output-a", 43: "output-b"])
        let monitor = M1SystemAudioLifecycleMonitor(operations: operations, timing: .immediate)
        let events = LockedLifecycleEvents()
        try monitor.start { events.append($0) }

        operations.triggerSystem(kAudioHardwarePropertyDevices)
        operations.drainCallbacks()
        XCTAssertTrue(events.values().isEmpty)

        operations.setDeviceID(43)
        operations.triggerSystem(kAudioHardwarePropertyDevices)
        events.waitForCount(1)
        XCTAssertEqual(events.values(), [.systemAudioServicesChanged])

        operations.setDeviceID(AudioObjectID(kAudioObjectUnknown))
        operations.triggerSystem(kAudioHardwarePropertyDefaultOutputDevice)
        events.waitForCount(2)
        XCTAssertEqual(events.values().last, .routeChanged)
        monitor.stop()
    }

    func testRebindRetriesAreBoundedAndReportMonitoringFailure() throws {
        let operations = LifecycleOperationsFake(deviceID: 42, uids: [42: "output-a"])
        let scheduler = LifecycleSchedulerFake()
        let monitor = M1SystemAudioLifecycleMonitor(
            operations: operations,
            timing: scheduler.timing
        )
        let events = LockedLifecycleEvents()
        try monitor.start { events.append($0) }
        operations.setReadFailures(4)

        operations.triggerSystem(kAudioHardwarePropertyDefaultOutputDevice)
        events.waitForCount(1)
        XCTAssertEqual(events.values().first, .routeChanged)
        XCTAssertEqual(scheduler.delays(), [250_000_000])

        scheduler.fireNext()
        XCTAssertEqual(scheduler.delays(), [1_000_000_000])
        scheduler.fireNext()
        XCTAssertEqual(scheduler.delays(), [1_000_000_000])
        scheduler.fireNext()
        events.waitForCount(2)
        XCTAssertEqual(events.values().last, .monitoringFailed)
        XCTAssertTrue(scheduler.delays().isEmpty)
        monitor.stop()
    }

    func testStaleScheduledRebindAndRetiredListenerRemovalAreSafe() throws {
        let operations = LifecycleOperationsFake(deviceID: 42, uids: [42: "output-a", 43: "output-b"])
        let scheduler = LifecycleSchedulerFake()
        let monitor = M1SystemAudioLifecycleMonitor(operations: operations, timing: scheduler.timing)
        try monitor.start { _ in }
        operations.setRemovalFailures(1)
        operations.setReadFailures(1)
        operations.triggerSystem(kAudioHardwarePropertyDevices)
        scheduler.waitForScheduledCount(1)

        operations.setDeviceID(43)
        operations.triggerSystem(kAudioHardwarePropertyDefaultOutputDevice)
        scheduler.fireNext()
        monitor.stop()

        XCTAssertGreaterThan(
            operations.removedDeviceSelectors().count,
            LifecycleOperationsFake.deviceSelectors.count
        )
    }

    func testWorkspaceSleepAndWakeNotificationsAreForwarded() throws {
        let operations = LifecycleOperationsFake(deviceID: 42, uids: [42: "output-a"])
        let monitor = M1SystemAudioLifecycleMonitor(operations: operations, timing: .immediate)
        let events = LockedLifecycleEvents()
        try monitor.start { events.append($0) }

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        events.waitForCount(2)
        XCTAssertEqual(events.values(), [.willSleep, .didWake])
        monitor.stop()
    }

    func testStartFailureRollsBackPartialRegistration() {
        let operations = LifecycleOperationsFake(deviceID: 42, uids: [42: "output-a"])
        operations.setAddFailure(selector: kAudioHardwarePropertyDevices)
        let monitor = M1SystemAudioLifecycleMonitor(operations: operations)

        XCTAssertThrowsError(try monitor.start { _ in })
        XCTAssertEqual(operations.removedSystemSelectors(), [kAudioHardwarePropertyDefaultOutputDevice])
        monitor.stop()
    }
}

private extension M1AudioLifecycleTiming {
    static let immediate = M1AudioLifecycleTiming { queue, _, action in
        queue.async(execute: action)
    }
}

private final class LifecycleOperationsFake: M1AudioLifecycleSystemOperations, @unchecked Sendable {
    struct Registration {
        let objectID: AudioObjectID
        let selector: AudioObjectPropertySelector
        let scope: AudioObjectPropertyScope
        let queue: DispatchQueue
        let listener: AudioObjectPropertyListenerBlock
    }

    static let deviceSelectors: [AudioObjectPropertySelector] = [
        kAudioDevicePropertyDeviceIsAlive,
        kAudioDevicePropertyNominalSampleRate,
        kAudioDevicePropertyStreamConfiguration,
        kAudioDevicePropertyPreferredChannelLayout,
        kAudioDevicePropertyPreferredChannelsForStereo,
    ]

    private let lock = NSLock()
    private var deviceID: AudioObjectID
    private let uids: [AudioObjectID: String]
    private var registrations: [Registration] = []
    private var removed: [Registration] = []
    private var readFailures = 0
    private var removalFailures = 0
    private var addFailureSelector: AudioObjectPropertySelector?

    init(deviceID: AudioObjectID, uids: [AudioObjectID: String]) {
        self.deviceID = deviceID
        self.uids = uids
    }

    func readDefaultOutputDevice() throws -> AudioObjectID {
        try lock.withLock {
            if readFailures > 0 {
                readFailures -= 1
                throw LifecycleOperationsError.injected
            }
            return deviceID
        }
    }

    func readDeviceUID(_ deviceID: AudioObjectID) throws -> String {
        guard let uid = uids[deviceID] else { throw LifecycleOperationsError.injected }
        return uid
    }

    func addPropertyListener(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        lock.withLock {
            if addFailureSelector == selector { return kAudioHardwareUnspecifiedError }
            registrations.append(.init(
                objectID: objectID,
                selector: selector,
                scope: scope,
                queue: queue,
                listener: listener
            ))
            return noErr
        }
    }

    func removePropertyListener(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        lock.withLock {
            guard let index = registrations.firstIndex(where: {
                $0.objectID == objectID && $0.selector == selector && $0.scope == scope
            }) else { return noErr }
            if removalFailures > 0 {
                removalFailures -= 1
                return kAudioHardwareUnspecifiedError
            }
            removed.append(registrations.remove(at: index))
            return noErr
        }
    }

    func triggerSystem(_ selectors: AudioObjectPropertySelector...) {
        trigger(objectID: AudioObjectID(kAudioObjectSystemObject), selectors: selectors)
    }

    func triggerDevice(_ selectors: AudioObjectPropertySelector...) {
        let current = lock.withLock { deviceID }
        trigger(objectID: current, selectors: selectors)
    }

    private func trigger(objectID: AudioObjectID, selectors: [AudioObjectPropertySelector]) {
        let registration = lock.withLock {
            registrations.last { $0.objectID == objectID && selectors.contains($0.selector) }
        }
        guard let registration else { return }
        registration.queue.async {
            let addresses = selectors.map {
                AudioObjectPropertyAddress(
                    mSelector: $0,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
            }
            addresses.withUnsafeBufferPointer { buffer in
                registration.listener(UInt32(buffer.count), buffer.baseAddress!)
            }
        }
    }

    func drainCallbacks() {
        let queues = lock.withLock { registrations.map(\.queue) }
        queues.forEach { $0.sync {} }
    }

    func setDeviceID(_ value: AudioObjectID) { lock.withLock { deviceID = value } }
    func setReadFailures(_ count: Int) { lock.withLock { readFailures = count } }
    func setRemovalFailures(_ count: Int) { lock.withLock { removalFailures = count } }
    func setAddFailure(selector: AudioObjectPropertySelector) { lock.withLock { addFailureSelector = selector } }

    func addedSystemSelectors() -> [AudioObjectPropertySelector] {
        lock.withLock {
            registrations.filter { $0.objectID == AudioObjectID(kAudioObjectSystemObject) }.map(\.selector)
        }
    }

    func addedDeviceSelectors() -> [AudioObjectPropertySelector] {
        lock.withLock {
            registrations.filter { $0.objectID != AudioObjectID(kAudioObjectSystemObject) }.map(\.selector)
        }
    }

    func removedSystemSelectors() -> [AudioObjectPropertySelector] {
        lock.withLock {
            removed.filter { $0.objectID == AudioObjectID(kAudioObjectSystemObject) }.map(\.selector)
        }
    }

    func removedDeviceSelectors() -> [AudioObjectPropertySelector] {
        lock.withLock {
            removed.filter { $0.objectID != AudioObjectID(kAudioObjectSystemObject) }.map(\.selector)
        }
    }
}

private final class LifecycleSchedulerFake: @unchecked Sendable {
    private struct Scheduled {
        let queue: DispatchQueue
        let delay: UInt64
        let action: @Sendable () -> Void
    }

    private let condition = NSCondition()
    private var scheduled: [Scheduled] = []

    var timing: M1AudioLifecycleTiming {
        M1AudioLifecycleTiming { [weak self] queue, delay, action in
            guard let self else { return }
            condition.withLock {
                scheduled.append(.init(queue: queue, delay: delay, action: action))
                condition.broadcast()
            }
        }
    }

    func delays() -> [UInt64] { condition.withLock { scheduled.map(\.delay) } }

    func fireNext() {
        let next = condition.withLock { scheduled.removeFirst() }
        next.queue.sync(execute: next.action)
    }

    func waitForScheduledCount(_ count: Int) {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(1)
        while scheduled.count < count && condition.wait(until: deadline) {}
        XCTAssertGreaterThanOrEqual(scheduled.count, count)
    }
}

private final class LockedLifecycleEvents: @unchecked Sendable {
    private let condition = NSCondition()
    private var events: [M1AudioLifecycleEvent] = []

    func append(_ event: M1AudioLifecycleEvent) {
        condition.withLock {
            events.append(event)
            condition.broadcast()
        }
    }

    func values() -> [M1AudioLifecycleEvent] { condition.withLock { events } }

    func waitForCount(_ count: Int) {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(1)
        while events.count < count && condition.wait(until: deadline) {}
        XCTAssertGreaterThanOrEqual(events.count, count)
    }

}

private enum LifecycleOperationsError: Error {
    case injected
}
