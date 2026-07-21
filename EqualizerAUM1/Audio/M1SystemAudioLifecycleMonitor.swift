import AppKit
import CoreAudio
import Foundation

protocol M1AudioLifecycleMonitoring: AnyObject {
    func start(handler: @escaping @Sendable (M1AudioLifecycleEvent) -> Void) throws
    func stop()
}

final class M1SystemAudioLifecycleMonitor: M1AudioLifecycleMonitoring, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.ruimingchen.EqualizerAU.audio-lifecycle")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var handler: (@Sendable (M1AudioLifecycleEvent) -> Void)?
    private var currentDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var currentDeviceUID = ""
    private var workspaceObservers: [NSObjectProtocol] = []
    private var isStarted = false
    private var rebindAttempt = 0
    private var rebindGeneration: UInt64 = 0

    private lazy var systemListener: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
        self?.handleSystemProperties(count: count, addresses: addresses)
    }
    private lazy var deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.handler?(.routeChanged)
    }

    init() {
        queue.setSpecific(key: queueKey, value: 1)
    }

    func start(handler: @escaping @Sendable (M1AudioLifecycleEvent) -> Void) throws {
        let startOnQueue = {
            guard !self.isStarted else { return }
            self.handler = handler
            do {
                try self.addSystemListener(kAudioHardwarePropertyDefaultOutputDevice)
                try self.addSystemListener(kAudioHardwarePropertyDevices)
                try self.bindDefaultOutputDevice()
                self.addWorkspaceObservers()
                self.isStarted = true
            } catch {
                self.removeRegisteredListeners()
                self.handler = nil
                throw error
            }
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            try startOnQueue()
        } else {
            try queue.sync(execute: startOnQueue)
        }
    }

    func stop() {
        let stopOnQueue = {
            guard self.isStarted || self.handler != nil else { return }
            self.removeRegisteredListeners()
            self.handler = nil
            self.isStarted = false
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopOnQueue()
        } else {
            queue.sync(execute: stopOnQueue)
        }
    }

    deinit {
        stop()
    }

    private func handleSystemProperties(
        count: UInt32,
        addresses: UnsafePointer<AudioObjectPropertyAddress>
    ) {
        var event: M1AudioLifecycleEvent?
        for index in 0..<Int(count) {
            switch addresses[index].mSelector {
            case kAudioHardwarePropertyDefaultOutputDevice:
                rebindAttempt = 0
                rebindDefaultOutputDevice()
                event = .routeChanged
            case kAudioHardwarePropertyDevices:
                rebindAttempt = 0
                rebindDefaultOutputDevice()
                event = .systemAudioServicesChanged
            default:
                break
            }
        }
        if let event { handler?(event) }
    }

    private func bindDefaultOutputDevice() throws {
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr else {
            throw M1CoreAudioStatusError(operation: "Monitor default output device", status: status)
        }
        if deviceID == AudioObjectID(kAudioObjectUnknown) {
            removeDeviceListeners(deviceID: currentDeviceID)
            currentDeviceID = deviceID
            currentDeviceUID = ""
            return
        }
        let deviceUID = try readDeviceUID(deviceID)
        guard deviceID != currentDeviceID || deviceUID != currentDeviceUID else { return }
        if deviceID == currentDeviceID {
            removeDeviceListeners(deviceID: currentDeviceID)
        }
        for selector in Self.deviceSelectors {
            var address = propertyAddress(selector, scope: Self.scope(for: selector))
            let addStatus = AudioObjectAddPropertyListenerBlock(
                deviceID,
                &address,
                queue,
                deviceListener
            )
            guard addStatus == noErr else {
                removeDeviceListeners(deviceID: deviceID)
                throw M1CoreAudioStatusError(operation: "Monitor output device", status: addStatus)
            }
        }
        let previousDeviceID = currentDeviceID
        currentDeviceID = deviceID
        currentDeviceUID = deviceUID
        if previousDeviceID != deviceID {
            removeDeviceListeners(deviceID: previousDeviceID)
        }
    }

    private func rebindDefaultOutputDevice() {
        do {
            try bindDefaultOutputDevice()
            rebindAttempt = 0
            rebindGeneration &+= 1
        } catch {
            scheduleRebind()
        }
    }

    private func scheduleRebind() {
        guard rebindAttempt < Self.maximumRebindAttempts else {
            handler?(.monitoringFailed)
            return
        }
        rebindAttempt += 1
        rebindGeneration &+= 1
        let generation = rebindGeneration
        let delay = rebindAttempt == 1 ? 250_000_000 : 1_000_000_000
        queue.asyncAfter(deadline: .now() + .nanoseconds(delay)) { [weak self] in
            guard let self,
                  self.isStarted,
                  generation == self.rebindGeneration
            else { return }
            self.rebindDefaultOutputDevice()
        }
    }

    private func addSystemListener(_ selector: AudioObjectPropertySelector) throws {
        var address = propertyAddress(selector)
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            systemListener
        )
        guard status == noErr else {
            throw M1CoreAudioStatusError(operation: "Monitor Core Audio system", status: status)
        }
    }

    private func addWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in self?.enqueue(.willSleep) },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in self?.enqueue(.didWake) },
        ]
    }

    private func enqueue(_ event: M1AudioLifecycleEvent) {
        queue.async { [weak self] in
            self?.handler?(event)
        }
    }

    private func removeRegisteredListeners() {
        rebindGeneration &+= 1
        rebindAttempt = 0
        removeDeviceListeners(deviceID: currentDeviceID)
        currentDeviceID = AudioObjectID(kAudioObjectUnknown)
        currentDeviceUID = ""
        for selector in [
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDevices,
        ] {
            var address = propertyAddress(selector)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                systemListener
            )
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
    }

    private func removeDeviceListeners(deviceID: AudioObjectID) {
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else { return }
        for selector in Self.deviceSelectors {
            var address = propertyAddress(selector, scope: Self.scope(for: selector))
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, deviceListener)
        }
    }

    private func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func readDeviceUID(_ deviceID: AudioObjectID) throws -> String {
        var address = propertyAddress(kAudioDevicePropertyDeviceUID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr, let value else {
            throw M1CoreAudioStatusError(operation: "Monitor output device UID", status: status)
        }
        let uid = value.takeRetainedValue() as String
        guard !uid.isEmpty else {
            throw M1CoreAudioStatusError(operation: "Monitor output device UID", status: kAudioHardwareBadObjectError)
        }
        return uid
    }

    private static let deviceSelectors: [AudioObjectPropertySelector] = [
        kAudioDevicePropertyDeviceIsAlive,
        kAudioDevicePropertyNominalSampleRate,
        kAudioDevicePropertyStreamConfiguration,
        kAudioDevicePropertyPreferredChannelLayout,
    ]
    private static let maximumRebindAttempts = 3

    private static func scope(for selector: AudioObjectPropertySelector) -> AudioObjectPropertyScope {
        selector == kAudioDevicePropertyStreamConfiguration
            ? kAudioObjectPropertyScopeOutput
            : kAudioObjectPropertyScopeGlobal
    }
}
