import CoreAudio
import Foundation

struct M1SystemAudioLifecycleOperations: M1AudioLifecycleSystemOperations, @unchecked Sendable {
    func readDefaultOutputDevice() throws -> AudioObjectID {
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
        return deviceID
    }

    func readDeviceUID(_ deviceID: AudioObjectID) throws -> String {
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

    func addPropertyListener(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        var address = propertyAddress(selector, scope: scope)
        return AudioObjectAddPropertyListenerBlock(objectID, &address, queue, listener)
    }

    func removePropertyListener(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        var address = propertyAddress(selector, scope: scope)
        return AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, listener)
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
}

extension M1SystemAudioLifecycleMonitor {
    convenience init() {
        self.init(operations: M1SystemAudioLifecycleOperations())
    }
}

