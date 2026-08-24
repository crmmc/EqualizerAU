import AppKit
import CoreAudio
import Foundation

protocol M1AudioLifecycleSystemOperations: Sendable {
    func readDefaultOutputDevice() throws -> AudioObjectID
    func readDeviceUID(_ deviceID: AudioObjectID) throws -> String
    func addPropertyListener(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus
    func removePropertyListener(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus
}

struct M1AudioLifecycleTiming: Sendable {
    let schedule: @Sendable (
        _ queue: DispatchQueue,
        _ delayNanoseconds: UInt64,
        _ action: @escaping @Sendable () -> Void
    ) -> Void

    static let production = M1AudioLifecycleTiming { queue, delay, action in
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(delay)), execute: action)
    }
}

final class M1SystemAudioLifecycleMonitor: M1AudioLifecycleMonitoring, @unchecked Sendable {
    private final class DeviceListenerActivation: @unchecked Sendable {
        var isActive = false
    }

    private final class DeviceListenerRegistration: @unchecked Sendable {
        let deviceID: AudioObjectID
        let listener: AudioObjectPropertyListenerBlock
        let activation: DeviceListenerActivation
        var selectors: [AudioObjectPropertySelector] = []

        init(
            deviceID: AudioObjectID,
            listener: @escaping AudioObjectPropertyListenerBlock,
            activation: DeviceListenerActivation
        ) {
            self.deviceID = deviceID
            self.listener = listener
            self.activation = activation
        }
    }

    private let queue = DispatchQueue(label: "com.ruimingchen.EqualizerAU.audio-lifecycle")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let operations: any M1AudioLifecycleSystemOperations
    private let timing: M1AudioLifecycleTiming
    private var handler: (@Sendable (M1AudioLifecycleEvent) -> Void)?
    private var currentDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var currentDeviceUID = ""
    private var currentDeviceRegistration: DeviceListenerRegistration?
    private var retiredDeviceRegistrations: [DeviceListenerRegistration] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var isStarted = false
    private var rebindAttempt = 0
    private var rebindGeneration: UInt64 = 0
    private var deviceListChangeTracker = M1AudioDeviceListChangeTracker()

    private lazy var systemListener: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
        self?.handleSystemProperties(count: count, addresses: addresses)
    }

    init(
        operations: any M1AudioLifecycleSystemOperations,
        timing: M1AudioLifecycleTiming = .production
    ) {
        self.operations = operations
        self.timing = timing
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
        var changes: Set<M1AudioSystemPropertyChange> = []
        for index in 0..<Int(count) {
            switch addresses[index].mSelector {
            case kAudioHardwarePropertyDefaultOutputDevice:
                changes.insert(.defaultOutput)
            case kAudioHardwarePropertyDevices:
                changes.insert(.deviceList)
            default:
                break
            }
        }
        guard !changes.isEmpty else { return }
        rebindAttempt = 0
        if changes.contains(.defaultOutput) {
            deviceListChangeTracker.cancel()
            rebindDefaultOutputDevice()
            handler?(.routeChanged)
        } else {
            deviceListChangeTracker.begin(previousOutput: monitoredOutputIdentity)
            rebindDefaultOutputDevice()
        }
    }

    private func handleDeviceProperties(
        count: UInt32,
        addresses: UnsafePointer<AudioObjectPropertyAddress>,
        output: M1MonitoredOutputIdentity
    ) {
        var changes: Set<M1AudioDevicePropertyChange> = []
        for index in 0..<Int(count) {
            switch addresses[index].mSelector {
            case kAudioDevicePropertyDeviceIsAlive:
                changes.insert(.alive)
            case kAudioDevicePropertyNominalSampleRate,
                 kAudioDevicePropertyStreamConfiguration,
                 kAudioDevicePropertyPreferredChannelLayout,
                 kAudioDevicePropertyPreferredChannelsForStereo:
                changes.insert(.outputFormat)
            default:
                break
            }
        }
        if let event = M1AudioDevicePropertyEventClassifier.event(
            for: changes,
            output: output
        ) {
            handler?(event)
        }
    }

    private var monitoredOutputIdentity: M1MonitoredOutputIdentity? {
        guard currentDeviceID != AudioObjectID(kAudioObjectUnknown), !currentDeviceUID.isEmpty else {
            return nil
        }
        return M1MonitoredOutputIdentity(
            objectID: UInt32(currentDeviceID),
            persistentUID: currentDeviceUID
        )
    }

    private func bindDefaultOutputDevice() throws {
        retryRetiredDeviceListeners()
        let deviceID = try operations.readDefaultOutputDevice()
        if deviceID == AudioObjectID(kAudioObjectUnknown) {
            retireCurrentDeviceRegistration()
            currentDeviceID = deviceID
            currentDeviceUID = ""
            return
        }
        let deviceUID = try operations.readDeviceUID(deviceID)
        guard deviceID != currentDeviceID || deviceUID != currentDeviceUID else { return }
        let outputIdentity = M1MonitoredOutputIdentity(
            objectID: UInt32(deviceID),
            persistentUID: deviceUID
        )
        let activation = DeviceListenerActivation()
        let newDeviceListener: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
            guard activation.isActive else { return }
            self?.handleDeviceProperties(
                count: count,
                addresses: addresses,
                output: outputIdentity
            )
        }
        let registration = DeviceListenerRegistration(
            deviceID: deviceID,
            listener: newDeviceListener,
            activation: activation
        )
        for selector in Self.deviceSelectors {
            let addStatus = operations.addPropertyListener(
                objectID: deviceID,
                selector: selector,
                scope: Self.scope(for: selector),
                queue: queue,
                listener: registration.listener
            )
            guard addStatus == noErr else {
                retainIfRemovalFails(registration)
                throw M1CoreAudioStatusError(operation: "Monitor output device", status: addStatus)
            }
            registration.selectors.append(selector)
        }
        registration.activation.isActive = true
        retireCurrentDeviceRegistration()
        currentDeviceID = deviceID
        currentDeviceUID = deviceUID
        currentDeviceRegistration = registration
    }

    private func rebindDefaultOutputDevice() {
        do {
            try bindDefaultOutputDevice()
            rebindAttempt = 0
            rebindGeneration &+= 1
            if let event = deviceListChangeTracker.finish(
                currentOutput: monitoredOutputIdentity
            ) {
                handler?(event)
            }
        } catch {
            scheduleRebind()
        }
    }

    private func scheduleRebind() {
        guard rebindAttempt < Self.maximumRebindAttempts else {
            deviceListChangeTracker.cancel()
            handler?(.monitoringFailed)
            return
        }
        rebindAttempt += 1
        rebindGeneration &+= 1
        let generation = rebindGeneration
        let delay: UInt64 = rebindAttempt == 1 ? 250_000_000 : 1_000_000_000
        timing.schedule(queue, delay) { [weak self] in
            guard let self,
                  self.isStarted,
                  generation == self.rebindGeneration
            else { return }
            self.rebindDefaultOutputDevice()
        }
    }

    private func addSystemListener(_ selector: AudioObjectPropertySelector) throws {
        let status = operations.addPropertyListener(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: selector,
            scope: kAudioObjectPropertyScopeGlobal,
            queue: queue,
            listener: systemListener
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
        deviceListChangeTracker.cancel()
        retireCurrentDeviceRegistration()
        retryRetiredDeviceListeners()
        currentDeviceID = AudioObjectID(kAudioObjectUnknown)
        currentDeviceUID = ""
        for selector in [
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDevices,
        ] {
            _ = operations.removePropertyListener(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                selector: selector,
                scope: kAudioObjectPropertyScopeGlobal,
                queue: queue,
                listener: systemListener
            )
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
    }

    private func retireCurrentDeviceRegistration() {
        guard let registration = currentDeviceRegistration else { return }
        currentDeviceRegistration = nil
        registration.activation.isActive = false
        retainIfRemovalFails(registration)
    }

    private func retainIfRemovalFails(_ registration: DeviceListenerRegistration) {
        registration.selectors = registration.selectors.filter { selector in
            operations.removePropertyListener(
                objectID: registration.deviceID,
                selector: selector,
                scope: Self.scope(for: selector),
                queue: queue,
                listener: registration.listener
            ) != noErr
        }
        if !registration.selectors.isEmpty {
            retiredDeviceRegistrations.append(registration)
        }
    }

    private func retryRetiredDeviceListeners() {
        let registrations = retiredDeviceRegistrations
        retiredDeviceRegistrations.removeAll(keepingCapacity: true)
        registrations.forEach(retainIfRemovalFails)
    }

    private static let deviceSelectors: [AudioObjectPropertySelector] = [
        kAudioDevicePropertyDeviceIsAlive,
        kAudioDevicePropertyNominalSampleRate,
        kAudioDevicePropertyStreamConfiguration,
        kAudioDevicePropertyPreferredChannelLayout,
        kAudioDevicePropertyPreferredChannelsForStereo,
    ]
    private static let maximumRebindAttempts = 3

    private static func scope(for selector: AudioObjectPropertySelector) -> AudioObjectPropertyScope {
        switch selector {
        case kAudioDevicePropertyStreamConfiguration,
             kAudioDevicePropertyPreferredChannelLayout,
             kAudioDevicePropertyPreferredChannelsForStereo:
            kAudioObjectPropertyScopeOutput
        default:
            kAudioObjectPropertyScopeGlobal
        }
    }
}
