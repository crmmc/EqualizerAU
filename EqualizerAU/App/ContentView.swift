import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("EqualizerAU")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text(model.virtualRouteState.rawValue)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(statusColor)
            }

            HStack {
                if model.virtualRouteState == .starting
                    || model.virtualRouteState == .running
                    || model.virtualRouteState == .failed {
                    Button(action: model.stopVirtualRouteProof) {
                        Label("Stop & Restore Route", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .accessibilityIdentifier("stopVirtualRoute")
                } else {
                    Button(action: model.startVirtualRouteProof) {
                        Label("Start Virtual Route Proof", systemImage: "waveform.path")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.virtualRouteState != .ready || model.audioState != .stopped)
                    .accessibilityIdentifier("startVirtualRoute")
                }

                Button(action: model.refreshVirtualRoutePrerequisite) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Check BlackHole 2ch installation")
                .disabled(model.virtualRouteState == .starting
                    || model.virtualRouteState == .running
                    || model.virtualRouteState == .stopping)
                .accessibilityIdentifier("refreshVirtualRoute")

                if model.audioState != .stopped {
                    Button(action: model.stop) {
                        Label("Stop Audio", systemImage: "stop.fill")
                    }
                    .accessibilityIdentifier("stopAudio")
                }

                Spacer()
            }

#if DEBUG
            HStack {
                if model.audioState == .stopped {
                    Button(action: model.start) {
                        Label("Start Native Route Test", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.outputIsolationState == .running
                        || model.virtualRouteState == .starting
                        || model.virtualRouteState == .running
                        || model.virtualRouteState == .stopping)
                    .accessibilityIdentifier("startAudio")
                }

                if model.outputIsolationState == .running {
                    Button(action: model.cancelOutputIsolationTest) {
                        Label("Stop Parity Test", systemImage: "stop.fill")
                    }
                    .tint(.red)
                    .accessibilityIdentifier("stopOutputIsolation")
                } else {
                    Button(action: model.runOutputIsolationTest) {
                        Label("Run Resonance Parity Test", systemImage: "waveform.badge.magnifyingglass")
                    }
                    .disabled(model.audioState != .stopped
                        || model.virtualRouteState == .starting
                        || model.virtualRouteState == .running
                        || model.virtualRouteState == .stopping)
                    .accessibilityIdentifier("runOutputIsolation")
                }
                Spacer()
            }
#endif

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                        statusRow(label: "BlackHole prerequisite", value: model.virtualRouteState.rawValue)
                        statusRow(label: "Virtual route", value: model.virtualRouteSummary)
                        statusRow(label: "Physical output", value: model.outputDeviceName)
#if DEBUG
                        statusRow(label: "Native route", value: model.audioState.rawValue)
                        statusRow(label: "Resonance parity", value: model.outputIsolationState.rawValue)
                        statusRow(label: "Parity result", value: model.outputIsolationSummary)
#endif
                    }

                    if let lastError = model.lastError {
                        Label(lastError, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("lastError")
                    } else {
                        Text("No active error")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .task {
            model.refreshVirtualRoutePrerequisite()
        }
    }

    private var statusColor: Color {
        switch model.virtualRouteState {
        case .running, .ready:
            return .green
        case .failed, .missing:
            return .orange
        case .starting, .stopping, .checking:
            return .blue
        }
    }

    private func statusRow(label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
