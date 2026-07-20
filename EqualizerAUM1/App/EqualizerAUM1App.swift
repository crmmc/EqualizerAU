import AppKit
import SwiftUI

enum M1RuntimeBootstrap {
    static var abiVersion: UInt32 { EAUM1RuntimeABIVersion() }
}

@MainActor
final class M1AppModel: ObservableObject {
    @Published private(set) var snapshot = M1ProductSnapshot(
        draft: .transparentRecovery,
        selectedNodeID: nil,
        persistence: .recovery,
        audio: .stopped,
        outputLayout: nil,
        activeDiagnostics: nil,
        expectedDiagnostics: nil,
        canEdit: false,
        canSetEffects: false,
        canSave: false,
        canStart: false,
        canStop: false,
        visibleError: nil
    )

    let controller: M1ProductController
    private var didBootstrap = false
    private var editTask: Task<Void, Never>?

    init(controller: M1ProductController) {
        self.controller = controller
    }

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        perform { await self.controller.bootstrap() }
    }

    func select(_ id: UUID?) {
        performEdit { await self.controller.selectNode(id) }
    }

    func add(before id: UUID?) {
        performEdit { try await self.controller.addPreamp(before: id) }
    }

    func delete(_ id: UUID) {
        performEdit { try await self.controller.deletePreamp(id: id) }
    }

    func move(_ id: UUID, to index: Int) {
        performEdit { try await self.controller.movePreamp(id: id, to: index) }
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        performEdit { try await self.controller.setNodeEnabled(id: id, enabled: enabled) }
    }

    func setGain(_ gain: Double, id: UUID) {
        performEdit { try await self.controller.setGainDB(id: id, gainDB: gain) }
    }

    func setChannels(_ channels: M1ChannelSelection, id: UUID) {
        performEdit { try await self.controller.setChannels(id: id, channels: channels) }
    }

    func save() { perform { try await self.controller.save() } }
    func start() {
        Task {
            do {
                let configuration = try await controller.beginStart()
                snapshot = await controller.snapshot()
                try await controller.finishStart(configuration: configuration)
            } catch {}
            snapshot = await controller.snapshot()
        }
    }
    func stop() { perform { try await self.controller.stop() } }
    func retryPersistence() { perform { try await self.controller.retryUncertainPersistence() } }
    func retryOutput() { perform { try await self.controller.retryOutputDiscovery() } }
    func setEffects(_ enabled: Bool) { perform { try await self.controller.setEffectsEnabled(enabled) } }

    func shutdown() async throws {
        try await controller.shutdown()
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            async let operationResult: Void = operation()
            await Task.yield()
            snapshot = await controller.snapshot()
            do { try await operationResult } catch {}
            snapshot = await controller.snapshot()
            if snapshot.expectedDiagnostics != nil {
                await controller.waitForPendingApplication()
                snapshot = await controller.snapshot()
            }
        }
    }

    private func performEdit(_ operation: @escaping @MainActor () async throws -> Void) {
        let predecessor = editTask
        editTask = Task {
            await predecessor?.value
            do { try await operation() } catch {}
            snapshot = await controller.snapshot()
        }
    }
}

@MainActor
private final class M1TerminationDelegate: NSObject, NSApplicationDelegate {
    weak var model: M1AppModel?
    private var terminationPending = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task {
            do {
                try await model.shutdown()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                self.terminationPending = false
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}

private final class M1RouteHolder: @unchecked Sendable {
    var route: M1NativeAudioRouteCoordinator?
    weak var controller: M1ProductController?
}

@main
struct EqualizerAUM1App: App {
    @NSApplicationDelegateAdaptor(M1TerminationDelegate.self) private var appDelegate
    @StateObject private var model: M1AppModel

    init() {
        let holder = M1RouteHolder()
        let runtimeAccess = M1RuntimeLeaseAccess { reason, generation in
            await holder.controller?.handleRecoverableStop(
                bridgeGeneration: generation,
                reason: reason
            )
        }
        let maintenance = M1RetirementMaintenanceCoordinator(
            access: runtimeAccess,
            timing: M1RetirementMaintenanceTiming(
                nowNanoseconds: { DispatchTime.now().uptimeNanoseconds },
                sleep: { try await Task.sleep(nanoseconds: $0) }
            )
        )
        let route = M1NativeAudioRouteCoordinator(
            routeResources: M1AudioRouteResourceController(operations: M1SystemHALRouteOperations()),
            audioIO: M1AudioIOController(
                operations: M1SystemAudioIOOperations(),
                timing: M1AudioIOControlTiming(
                    nowNanoseconds: { DispatchTime.now().uptimeNanoseconds },
                    sleep: { try await Task.sleep(nanoseconds: $0) }
                )
            ),
            runtimeFactory: M1SystemRuntimeFactory(),
            runtimeAccess: runtimeAccess,
            retirementMaintenance: maintenance
        )
        holder.route = route
        let controller = M1ProductController(
            store: M1ConfigurationStore.applicationSupportStore(),
            audio: route
        )
        holder.controller = controller
        _model = StateObject(wrappedValue: M1AppModel(controller: controller))
    }

    var body: some Scene {
        WindowGroup {
            M1EditorView(model: model)
                .onAppear {
                    appDelegate.model = model
                    model.bootstrap()
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 760, height: 520)
        .commands {
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.save() }
                    .keyboardShortcut("s")
                    .disabled(!model.snapshot.canSave)
            }
        }
    }
}

private struct M1EditorView: View {
    @ObservedObject var model: M1AppModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            chain
            Divider()
            status
        }
        .frame(minWidth: 620, minHeight: 420)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                if model.snapshot.canStop {
                    model.stop()
                } else {
                    model.start()
                }
            } label: {
                Image(systemName: model.snapshot.canStop ? "stop.fill" : "play.fill")
            }
            .help(model.snapshot.canStop ? "Stop processing" : "Start processing")
            .disabled(!model.snapshot.canStop && !model.snapshot.canStart)

            Toggle(
                "Effects",
                isOn: Binding(
                    get: { model.snapshot.draft.effectsEnabled },
                    set: { model.setEffects($0) }
                )
            )
            .toggleStyle(.switch)
            .disabled(!model.snapshot.canSetEffects)

            Spacer()

            if case .uncertain = model.snapshot.persistence {
                Button("Retry") { model.retryPersistence() }
            }
            if case .waitingForOutput = model.snapshot.persistence {
                Button("Retry Output") { model.retryOutput() }
            }
            Button { model.save() } label: { Image(systemName: "square.and.arrow.down") }
                .help("Save configuration")
                .disabled(!model.snapshot.canSave)
        }
        .padding(12)
    }

    private var chain: some View {
        List(selection: Binding(
            get: { model.snapshot.selectedNodeID },
            set: { model.select($0) }
        )) {
            ForEach(Array(model.snapshot.draft.nodes.enumerated()), id: \.element.id) { index, node in
                HStack(spacing: 10) {
                    Button { model.add(before: node.id) } label: {
                        Image(systemName: "plus")
                    }
                    .help("Add Preamp before")

                    Toggle("", isOn: Binding(
                        get: { node.isEnabled },
                        set: { model.setEnabled($0, id: node.id) }
                    ))
                    .labelsHidden()

                    Text("Preamp")
                        .frame(width: 70, alignment: .leading)

                    Menu {
                        Button("All") { model.setChannels(.all, id: node.id) }
                        ForEach(channelIdentifiers(for: node), id: \.self) { identifier in
                            Toggle(
                                identifier.rawValue,
                                isOn: Binding(
                                    get: { selectedIdentifiers(node.channels).contains(identifier) },
                                    set: { selected in
                                        model.setChannels(
                                            updatedChannels(node.channels, identifier: identifier, selected: selected),
                                            id: node.id
                                        )
                                    }
                                )
                            )
                        }
                    } label: {
                        Text(channelSummary(node.channels))
                    }
                    .frame(width: 110, alignment: .leading)

                    Slider(
                        value: Binding(
                            get: { node.gainDB },
                            set: { model.setGain($0, id: node.id) }
                        ),
                        in: -20...20,
                        step: 0.1
                    )
                    TextField(
                        "Gain",
                        value: Binding(
                            get: { node.gainDB },
                            set: { model.setGain(min(max($0, -100), 100), id: node.id) }
                        ),
                        format: .number.precision(.fractionLength(1))
                    )
                        .textFieldStyle(.roundedBorder)
                        .monospacedDigit()
                        .frame(width: 58)
                    Text("dB").foregroundStyle(.secondary)

                    Button { model.move(node.id, to: index - 1) } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(index == 0)
                    .help("Move up")
                    Button { model.move(node.id, to: index + 1) } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(index == model.snapshot.draft.nodes.count - 1)
                    .help("Move down")
                    Button { model.delete(node.id) } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete Preamp")
                }
                .tag(node.id)
                .disabled(!model.snapshot.canEdit)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { model.add(before: nil) } label: {
                    Label("Preamp", systemImage: "plus")
                }
                .disabled(!model.snapshot.canEdit)
                Spacer()
            }
            .padding(10)
            .background(.bar)
        }
    }

    private var status: some View {
        HStack {
            Image(systemName: statusIcon)
            Text(statusText)
            Spacer()
            if let layout = model.snapshot.outputLayout {
                Text("\(layout.channels.count) ch  \(Int(layout.sampleRate)) Hz")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(10)
    }

    private var statusIcon: String {
        model.snapshot.visibleError == nil ? "checkmark.circle" : "exclamationmark.triangle"
    }

    private var statusText: String {
        if let error = model.snapshot.visibleError { return error }
        return "\(String(describing: model.snapshot.audio)) · \(String(describing: model.snapshot.persistence))"
    }

    private func channelSummary(_ selection: M1ChannelSelection) -> String {
        switch selection {
        case .all: return "All"
        case let .identifiers(values): return values.map(\.rawValue).joined(separator: ", ")
        }
    }

    private func selectedIdentifiers(_ selection: M1ChannelSelection) -> [M1ChannelIdentifier] {
        if case let .identifiers(values) = selection { return values }
        return []
    }

    private func channelIdentifiers(for node: M1PreampNode) -> [M1ChannelIdentifier] {
        var result = selectedIdentifiers(node.channels)
        for channel in model.snapshot.outputLayout?.channels ?? []
        where !result.contains(channel.identifier) {
            result.append(channel.identifier)
        }
        return result
    }

    private func updatedChannels(
        _ selection: M1ChannelSelection,
        identifier: M1ChannelIdentifier,
        selected: Bool
    ) -> M1ChannelSelection {
        var identifiers = selectedIdentifiers(selection)
        if selected {
            if !identifiers.contains(identifier) { identifiers.append(identifier) }
        } else {
            identifiers.removeAll { $0 == identifier }
        }
        return identifiers.isEmpty ? .all : .identifiers(identifiers)
    }
}
