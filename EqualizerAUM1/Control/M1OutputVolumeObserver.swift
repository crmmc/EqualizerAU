import CoreAudio
import Foundation

/// A volume reading from the current default output device.
struct M1OutputVolumeReading: Equatable, Sendable {
    let decibels: Double
    let usesApproximateConversion: Bool
}

/// Control-layer observer for the system default output device's volume knob
/// (ADR-0023 decision 4). Attaches Core Audio property listeners on its own
/// thread and reports readings through a Sendable callback; the realtime path
/// is never touched. The default-device choice matches the current product
/// scope (default output only, PRD §12).
final class M1OutputVolumeObserver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "EqualizerAU.M1OutputVolumeObserver")
    private let onReading: @Sendable (M1OutputVolumeReading) -> Void

    // Listener procs are stored once so registration and removal present the
    // same function value: Core Audio matches removal by proc + context, and
    // separate closure literals would compile to distinct C thunks that do not
    // match each other on removal.
    //
    // The context is passed unretained. The accepted narrow window — a HAL
    // callback dereferencing the context after the last strong release but
    // before removal — cannot occur in the shipped lifecycle: the controller
    // retains the observer from bootstrap until shutdown(), which stops the
    // listeners (AudioObjectRemovePropertyListener drains in-flight
    // invocations) before releasing the observer.
    private let systemPropertyListener: AudioObjectPropertyListenerProc = { _, _, _, context in
        guard let context else { return noErr }
        Unmanaged<M1OutputVolumeObserver>
            .fromOpaque(context)
            .takeUnretainedValue()
            .handleDefaultDeviceChange()
        return noErr
    }
    private let volumePropertyListener: AudioObjectPropertyListenerProc = { _, _, _, context in
        guard let context else { return noErr }
        Unmanaged<M1OutputVolumeObserver>
            .fromOpaque(context)
            .takeUnretainedValue()
            .handleVolumeChange()
        return noErr
    }

    private var systemAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private var observedDeviceID: AudioObjectID = kAudioObjectUnknown
    private var started = false

    init(onReading: @escaping @Sendable (M1OutputVolumeReading) -> Void) {
        self.onReading = onReading
    }

    deinit {
        stopListeners()
    }

    func start() {
        queue.sync {
            guard !started else { return }
            guard AudioObjectAddPropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &systemAddress,
                systemPropertyListener,
                Unmanaged.passUnretained(self).toOpaque()
            ) == noErr else { return }
            started = true
            attachToDevice()
        }
    }

    func stop() {
        queue.sync {
            guard started else { return }
            started = false
            stopListeners()
        }
    }

    // MARK: - Listener plumbing (observer queue)

    private func handleDefaultDeviceChange() {
        queue.async { self.attachToDevice() }
    }

    private func handleVolumeChange() {
        queue.async { self.readAndReport() }
    }

    private func attachToDevice() {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var deviceIDSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var query = systemAddress
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &query,
            0,
            nil,
            &deviceIDSize,
            &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else {
            detachFromDevice()
            return
        }
        // A default-device notification does not imply the device actually
        // changed; re-adding the listener for the device already observed
        // would stack registrations that detach only removes once. Just
        // re-read the volume on the existing listener.
        guard deviceID != observedDeviceID else {
            readAndReport()
            return
        }
        detachFromDevice()
        observedDeviceID = deviceID
        var address = volumeAddress
        guard AudioObjectAddPropertyListener(
            observedDeviceID,
            &address,
            volumePropertyListener,
            Unmanaged.passUnretained(self).toOpaque()
        ) == noErr else {
            observedDeviceID = kAudioObjectUnknown
            return
        }
        readAndReport()
    }

    private func detachFromDevice() {
        guard observedDeviceID != kAudioObjectUnknown else { return }
        var address = volumeAddress
        AudioObjectRemovePropertyListener(
            observedDeviceID,
            &address,
            volumePropertyListener,
            Unmanaged.passUnretained(self).toOpaque()
        )
        observedDeviceID = kAudioObjectUnknown
    }

    private func stopListeners() {
        detachFromDevice()
        var address = systemAddress
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            systemPropertyListener,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    // MARK: - Reading

    private func readAndReport() {
        guard observedDeviceID != kAudioObjectUnknown else { return }
        var scalar = Float32(0)
        var scalarSize = UInt32(MemoryLayout<Float32>.size)
        var address = volumeAddress
        guard AudioObjectGetPropertyData(
            observedDeviceID,
            &address,
            0,
            nil,
            &scalarSize,
            &scalar
        ) == noErr, scalar.isFinite, scalar >= 0, scalar <= 1 else { return }

        if let decibels = exactDecibels(forScalar: scalar) {
            onReading(
                M1OutputVolumeReading(
                    decibels: decibels,
                    usesApproximateConversion: false
                )
            )
        } else if let approximated = M1OutputVolumeMath.approximateDecibels(fromScalar: scalar) {
            onReading(
                M1OutputVolumeReading(
                    decibels: approximated,
                    usesApproximateConversion: true
                )
            )
        }
    }

    private func exactDecibels(forScalar scalar: Float32) -> Double? {
        var conversion = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalarToDecibels,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = scalar
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(
            observedDeviceID,
            &conversion,
            0,
            nil,
            &size,
            &value
        ) == noErr, value.isFinite, value > -200, value < 40 else {
            return nil
        }
        return Double(value)
    }
}
