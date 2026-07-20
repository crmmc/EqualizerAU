import Combine
import Foundation

enum AudioPermissionState: String, Equatable {
    case notDetermined = "Not determined"
    case tapCreated = "Tap created; audio not validated"
    case verified = "Verified by audio data"
    case unavailable = "Unavailable"
}

enum AudioRuntimeState: String, Equatable {
    case stopped = "Stopped"
    case starting = "Starting"
    case running = "Running"
    case stopping = "Stopping"
    case failed = "Failed"
}

enum OutputIsolationState: String, Equatable {
    case idle = "Ready"
    case running = "Running Resonance parity probe"
    case completed = "Resonance parity probe completed"
    case failed = "Failed"
}

enum VirtualRouteState: String, Equatable {
    case checking = "Checking BlackHole 2ch"
    case missing = "BlackHole 2ch not installed"
    case ready = "Ready for virtual route proof"
    case starting = "Starting virtual route"
    case running = "Running -12 dB virtual route"
    case stopping = "Restoring system audio"
    case failed = "Recovery required"
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var permissionState: AudioPermissionState = .notDetermined
    @Published private(set) var audioState: AudioRuntimeState = .stopped
    @Published private(set) var outputDeviceName = "Not queried"
    @Published private(set) var tapUID = "Not queried"
    @Published private(set) var tapFormat = "Not queried"
    @Published private(set) var lastError: String?

    @Published private(set) var outputIsolationState: OutputIsolationState = .idle
    @Published private(set) var outputIsolationSummary = "Not run"
    @Published private(set) var virtualRouteState: VirtualRouteState = .checking
    @Published private(set) var virtualRouteSummary = "Checking the exact BlackHole 2ch device contract"

    private let lifecycle: AudioLifecycleController
    private let outputIsolation: any AudioOutputIsolationRunning
    private let blackHoleDiscovery: any BlackHoleDeviceDiscovering
    private let virtualRouteLifecycle: BlackHoleAudioLifecycleController
    private var commandTask: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?
    private var isolationTask: Task<Void, Never>?
    private var virtualRouteTask: Task<Void, Never>?

    init(
        lifecycle: AudioLifecycleController = AudioLifecycleController(),
        outputIsolation: any AudioOutputIsolationRunning = AudioOutputIsolationTestController(),
        blackHoleDiscovery: any BlackHoleDeviceDiscovering = BlackHoleDeviceDiscovery(),
        virtualRouteLifecycle: BlackHoleAudioLifecycleController = BlackHoleAudioLifecycleController()
    ) {
        self.lifecycle = lifecycle
        self.outputIsolation = outputIsolation
        self.blackHoleDiscovery = blackHoleDiscovery
        self.virtualRouteLifecycle = virtualRouteLifecycle
    }

    func start() {
        guard audioState != .starting, audioState != .running, audioState != .stopping else { return }

        audioState = .starting
        lastError = nil

        commandTask = Task { [weak self, lifecycle] in
            do {
                let snapshot = try await lifecycle.start()
                guard let self, audioState == .starting else { return }
                publish(snapshot)
                permissionState = .tapCreated
                audioState = .running
                beginDiagnosticsRefresh()
            } catch {
                guard let self, audioState == .starting else { return }
                audioState = .failed
                lastError = error.localizedDescription
            }
        }
    }

    func stop() {
        guard audioState != .stopped, audioState != .stopping else { return }
        diagnosticsTask?.cancel()
        audioState = .stopping
        lastError = nil
        commandTask = Task { [weak self, lifecycle] in
            do {
                try await lifecycle.stop()
                guard let self else { return }
                audioState = .stopped
            } catch {
                guard let self else { return }
                audioState = .failed
                lastError = error.localizedDescription
            }
        }
    }

    func retry() {
        guard audioState == .failed else { return }
        diagnosticsTask?.cancel()
        audioState = .starting
        lastError = nil
        commandTask = Task { [weak self, lifecycle] in
            do {
                let snapshot = try await lifecycle.retry()
                guard let self, audioState == .starting else { return }
                publish(snapshot)
                permissionState = .tapCreated
                audioState = .running
                beginDiagnosticsRefresh()
            } catch {
                guard let self, audioState == .starting else { return }
                audioState = .failed
                lastError = error.localizedDescription
            }
        }
    }

    func runOutputIsolationTest() {
        guard audioState == .stopped,
              outputIsolationState != .running,
              virtualRouteState != .starting,
              virtualRouteState != .running,
              virtualRouteState != .stopping else { return }
        outputIsolationState = .running
        outputIsolationSummary = ".muted self-excluding Tap, then one nonce-coded output"
        lastError = nil
        isolationTask = Task { [weak self, outputIsolation] in
            do {
                let result = try await outputIsolation.run()
                guard let self else { return }
                outputIsolationState = .completed
                outputIsolationSummary = Self.isolationSummary(result)
            } catch AudioOutputIsolationError.cancelled {
                guard let self else { return }
                outputIsolationState = .idle
                outputIsolationSummary = "Stopped"
                lastError = nil
            } catch {
                guard let self else { return }
                outputIsolationState = .failed
                outputIsolationSummary = error.localizedDescription
                lastError = error.localizedDescription
            }
        }
    }

    func cancelOutputIsolationTest() {
        guard outputIsolationState == .running else { return }
        Task { [outputIsolation] in
            await outputIsolation.cancel()
        }
    }

    func refreshVirtualRoutePrerequisite() {
        guard virtualRouteState != .starting,
              virtualRouteState != .running,
              virtualRouteState != .stopping
        else { return }
        virtualRouteState = .checking
        virtualRouteSummary = "Checking the exact BlackHole 2ch device contract"
        virtualRouteTask = Task { [weak self, blackHoleDiscovery] in
            do {
                let device = try await blackHoleDiscovery.snapshot(
                    generation: AudioGeneration(rawValue: 0)
                )
                guard let self, virtualRouteState == .checking else { return }
                virtualRouteState = .ready
                virtualRouteSummary = "\(device.name), \(Int(device.nominalSampleRate)) Hz, 2 ch"
                lastError = nil
            } catch BlackHoleDeviceDiscoveryError.notInstalled {
                guard let self, virtualRouteState == .checking else { return }
                virtualRouteState = .missing
                virtualRouteSummary = "Install the official BlackHole 2ch device, then refresh"
                lastError = nil
            } catch {
                guard let self, virtualRouteState == .checking else { return }
                virtualRouteState = .failed
                virtualRouteSummary = error.localizedDescription
                lastError = error.localizedDescription
            }
        }
    }

    func startVirtualRouteProof() {
        guard virtualRouteState == .ready,
              audioState == .stopped,
              outputIsolationState != .running else { return }
        virtualRouteState = .starting
        virtualRouteSummary = "Preflighting endpoints before changing the system route"
        lastError = nil
        virtualRouteTask = Task { [weak self, virtualRouteLifecycle] in
            do {
                let snapshot = try await virtualRouteLifecycle.start()
                guard let self, virtualRouteState == .starting else { return }
                virtualRouteState = .running
                outputDeviceName = snapshot.physicalOutputName
                virtualRouteSummary = "System audio is routed through BlackHole at fixed -12 dB"
            } catch {
                guard let self else { return }
                virtualRouteState = .failed
                virtualRouteSummary = error.localizedDescription
                lastError = error.localizedDescription
            }
        }
    }

    func stopVirtualRouteProof() {
        guard virtualRouteState == .starting
                || virtualRouteState == .running
                || virtualRouteState == .failed
        else { return }
        virtualRouteState = .stopping
        virtualRouteSummary = "Fading output and restoring the previous system route"
        lastError = nil
        virtualRouteTask = Task { [weak self, virtualRouteLifecycle] in
            do {
                try await virtualRouteLifecycle.stop()
                guard let self else { return }
                virtualRouteState = .ready
                virtualRouteSummary = "Stopped; previous system route restored"
            } catch {
                guard let self else { return }
                virtualRouteState = .failed
                virtualRouteSummary = error.localizedDescription
                lastError = error.localizedDescription
            }
        }
    }

    private static func isolationSummary(_ result: AudioOutputIsolationResult) -> String {
        let correlation = String(format: "%.3f", result.attribution.capture.challengeCorrelation)
        let gain = String(format: "%.1f", result.attribution.capture.estimatedGainDB)
        let verdict = switch result.attribution.verdict {
        case .detected: "recapture detected"
        case .notDetected: "no recapture detected"
        case .inconclusive: "recapture inconclusive"
        }
        return "Nonce correlation \(correlation), matched gain \(gain) dB; \(verdict)"
    }

    private func beginDiagnosticsRefresh() {
        diagnosticsTask?.cancel()
        diagnosticsTask = Task { [weak self, lifecycle] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled,
                      let snapshot = await lifecycle.snapshot(),
                      let self
                else { continue }
                if snapshot.diagnostics.nonZeroSampleCount > 0 {
                    permissionState = .verified
                }
            }
        }
    }

    private func publish(_ snapshot: AudioPipelineSnapshot) {
        outputDeviceName = snapshot.outputDeviceName
        tapUID = snapshot.tapUID
        tapFormat = snapshot.tapFormat
    }
}
