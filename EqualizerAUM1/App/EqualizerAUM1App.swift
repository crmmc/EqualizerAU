import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let m1NodeDragType = UTType(exportedAs: "com.ruimingchen.equalizerau.preamp-node-drag")

enum M1RuntimeBootstrap {
    static var abiVersion: UInt32 { EAUM1RuntimeABIVersion() }
}

@MainActor
final class M1AppModel: ObservableObject {
    @Published private(set) var snapshot = M1ProductSnapshot(
        draft: .transparentRecovery,
        selectedNodeIDs: [],
        focusedNodeID: nil,
        persistence: .recovery,
        audio: .stopped,
        outputLayout: nil,
        activeDiagnostics: nil,
        expectedDiagnostics: nil,
        activeConfigurationGeneration: nil,
        expectedConfigurationGeneration: nil,
        realtimeDiagnostics: nil,
        appliedEffectsEnabled: nil,
        canEdit: false,
        canSetEffects: false,
        canSave: false,
        canStart: false,
        canStop: false,
        canUndo: false,
        canRedo: false,
        canUseSelection: false,
        hasUnsavedNodes: false,
        hasUnsavedEffects: false,
        visibleError: nil
    )

    let controller: M1ProductController
    private var didBootstrap = false
    private var commandTask: Task<Void, Never>?
    private var editTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var commandSequence: UInt64 = 0
    private var terminationPending = false
    private let pasteboard: any M1PasteboardAccess

    init(controller: M1ProductController, pasteboard: any M1PasteboardAccess = M1SystemPasteboard()) {
        self.controller = controller
        self.pasteboard = pasteboard
    }

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        perform { await self.controller.bootstrap() }
    }

    func select(_ id: UUID?, mode: M1SelectionMode) {
        performEdit { await self.controller.selectNode(id, mode: mode) }
    }

    func add(before id: UUID?) {
        performEdit { try await self.controller.addPreamp(before: id) }
    }

    func addChannels(before id: UUID?) {
        performEdit { try await self.controller.addChannels(before: id) }
    }

    func addGraphicEQ(before id: UUID?) {
        performEdit { try await self.controller.addGraphicEQ(before: id) }
    }

    func importConvolution(before id: UUID?) {
        guard let url = selectWAV() else { return }
        performEdit {
            let ir = try await Task.detached {
                try M1ConvolutionIRStore().importWAV(at: url)
            }.value
            try await self.controller.addConvolution(before: id, ir: ir)
        }
    }

    func replaceConvolutionIR(id: UUID) {
        guard let url = selectWAV() else { return }
        performEdit {
            let ir = try await Task.detached {
                try M1ConvolutionIRStore().importWAV(at: url)
            }.value
            try await self.controller.setConvolutionIR(id: id, ir: ir)
        }
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

    func setGraphicEQGain(_ gain: Double, bandIndex: Int, id: UUID) {
        performEdit {
            try await self.controller.setGraphicEQGainDB(
                id: id,
                bandIndex: bandIndex,
                gainDB: gain
            )
        }
    }

    func setChannels(_ channels: M1ChannelSelection, id: UUID) {
        performEdit { try await self.controller.setChannels(id: id, channels: channels) }
    }

    func beginGesture(_ id: UUID) { performEdit { await self.controller.beginEditGesture(id) } }
    func endGesture(_ id: UUID) { performEdit { await self.controller.endEditGesture(id) } }
    func undo() { performEdit { try await self.controller.undo() } }
    func redo() { performEdit { try await self.controller.redo() } }
    func selectAll() { performEdit { await self.controller.selectAllNodes() } }
    func moveFocus(by offset: Int, extending: Bool) {
        guard !(NSApp.keyWindow?.firstResponder is NSTextView) else { return }
        performEdit { await self.controller.moveSelectionFocus(by: offset, extending: extending) }
    }
    func deleteSelection() { performEdit { try await self.controller.deleteSelectedPreamps() } }
    func copy() { perform { try await self.controller.copySelection(to: self.pasteboard) } }
    func cut() { perform { try await self.controller.cutSelection(to: self.pasteboard) } }
    func paste() { performEdit { try await self.controller.paste(from: self.pasteboard) } }
    func moveSelection(to index: Int, operation: M1NodeDragOperation) {
        performEdit {
            try await self.controller.moveSelectedPreamps(to: index, operation: operation)
        }
    }

    func moveSelection(by offset: Int) {
        let indexed = snapshot.draft.nodes.enumerated().filter {
            snapshot.selectedNodeIDs.contains($0.element.id)
        }
        guard let first = indexed.first?.offset, let last = indexed.last?.offset else { return }
        moveSelection(to: offset < 0 ? first - 1 : last + 2, operation: .move)
    }

    func beginDrag(_ id: UUID) -> NSItemProvider {
        if !snapshot.selectedNodeIDs.contains(id) {
            select(id, mode: .replacing)
        }
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: m1NodeDragType.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(Data(), nil)
            return nil
        }
        return provider
    }

    func save() { perform { try await self.controller.save() } }
    func start() {
        guard !terminationPending else { return }
        let predecessor = commandTask
        commandSequence &+= 1
        commandTask = Task {
            await predecessor?.value
            do {
                let configuration = try await controller.beginStart()
                snapshot = await controller.snapshot()
                try await controller.finishStart(configuration: configuration)
            } catch {}
            snapshot = await controller.snapshot()
        }
    }
    func stop() {
        guard !terminationPending else { return }
        let predecessor = stopTask
        commandSequence &+= 1
        stopTask = Task {
            await predecessor?.value
            do {
                try await controller.stop()
            } catch {
                await controller.reportCommandError(String(describing: error))
            }
            snapshot = await controller.snapshot()
        }
    }
    func retryPersistence() { perform { try await self.controller.retryUncertainPersistence() } }
    func retryOutput() { perform { try await self.controller.retryOutputDiscovery() } }
    func refreshDiagnostics() { perform { try await self.controller.refreshDiagnostics() } }
    func setEffects(_ enabled: Bool) { perform { try await self.controller.setEffectsEnabled(enabled) } }
    func setProcessing(_ enabled: Bool) {
        perform { try await self.controller.setProcessingEnabled(enabled) }
    }

    private func selectWAV() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    func presentDiagnostics() {
        guard !terminationPending else { return }
        commandSequence &+= 1
        let predecessor = commandTask
        commandTask = Task {
            await predecessor?.value
            do {
                try await controller.refreshDiagnostics()
                snapshot = await controller.snapshot()
                let alert = NSAlert()
                alert.messageText = "Realtime Diagnostics"
                alert.informativeText = diagnosticsText(snapshot.realtimeDiagnostics)
                alert.addButton(withTitle: "OK")
                alert.runModal()
            } catch {
                await controller.reportCommandError(String(describing: error))
                snapshot = await controller.snapshot()
            }
        }
    }

    private func diagnosticsText(_ diagnostics: M1RealtimeDiagnostics?) -> String {
        guard let diagnostics else { return "No running audio route is available." }
        return """
        Captured frames: \(diagnostics.io.capturedFrames)
        Rendered frames: \(diagnostics.io.renderedFrames)
        Overflow blocks: \(diagnostics.io.overflowedBlocks)
        Underrun blocks: \(diagnostics.io.underrunBlocks)
        Dropped backlog frames: \(diagnostics.io.droppedBacklogFrames)
        Invalid callbacks/process calls: \(diagnostics.io.invalidCallbacks + diagnostics.runtime.invalidProcessCalls)
        Overlapping callbacks: \(diagnostics.io.overlappingRenderCallbacks + diagnostics.runtime.overlappingCallbacks)
        Non-finite input samples: \(diagnostics.runtime.nonFiniteInputSamples)
        Saturated output samples: \(diagnostics.runtime.saturatedOutputSamples)
        """
    }

    func shutdown() async throws {
        try await controller.shutdown()
    }

    func requestTermination() async -> M1TerminationDecision {
        terminationPending = true
        await drainCommands()
        let decision = await controller.requestTermination()
        snapshot = await controller.snapshot()
        if case .stayOpen = decision { terminationPending = false }
        return decision
    }

    func resolveTermination(_ action: M1TerminationAction) async -> M1TerminationDecision {
        await drainCommands()
        let decision = await controller.resolveTermination(action)
        snapshot = await controller.snapshot()
        if case .stayOpen = decision { terminationPending = false }
        return decision
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !terminationPending else { return }
        commandSequence &+= 1
        let predecessor = commandTask
        let precedingEdits = editTask
        let task = Task {
            await predecessor?.value
            await precedingEdits?.value
            async let operationResult: Void = operation()
            await Task.yield()
            snapshot = await controller.snapshot()
            do {
                try await operationResult
            } catch {
                await controller.reportCommandError(String(describing: error))
            }
            snapshot = await controller.snapshot()
            if snapshot.expectedDiagnostics != nil {
                await controller.waitForPendingApplication()
                snapshot = await controller.snapshot()
            }
        }
        commandTask = task
    }

    private func performEdit(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !terminationPending else { return }
        let predecessor = editTask
        commandSequence &+= 1
        editTask = Task {
            await predecessor?.value
            do {
                try await operation()
            } catch {
                await controller.reportCommandError(String(describing: error))
            }
            snapshot = await controller.snapshot()
        }
    }

    private func drainCommands() async {
        while true {
            let sequence = commandSequence
            let tail = commandTask
            let editTail = editTask
            let stopTail = stopTask
            await tail?.value
            await editTail?.value
            await stopTail?.value
            if sequence == commandSequence { return }
        }
    }
}

private final class M1SystemPasteboard: M1PasteboardAccess, @unchecked Sendable {
    private let type = NSPasteboard.PasteboardType("com.ruimingchen.equalizerau.preamp-nodes")

    func readNodes() async -> Data? {
        await MainActor.run { NSPasteboard.general.data(forType: type) }
    }

    func writeNodes(_ data: Data) async -> Bool {
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            return pasteboard.setData(data, forType: type)
        }
    }
}

@MainActor
private final class M1TerminationDelegate: NSObject, NSApplicationDelegate {
    weak var model: M1AppModel?
    var restoreEditorWindow: (() -> Void)?
    private var terminationPending = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task {
            var decision = await model.requestTermination()
            while case let .prompt(prompt) = decision {
                guard let action = self.present(prompt) else {
                    _ = await model.resolveTermination(.cancel)
                    self.terminationPending = false
                    self.restoreEditorWindow?()
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
                decision = await model.resolveTermination(action)
            }
            switch decision {
            case .terminate:
                sender.reply(toApplicationShouldTerminate: true)
            case .stayOpen, .prompt:
                self.terminationPending = false
                self.restoreEditorWindow?()
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    private func present(_ prompt: M1TerminationPrompt) -> M1TerminationAction? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch prompt {
        case .unsavedNodes:
            alert.messageText = "Save changes before quitting?"
            alert.informativeText = "Your Preamp edits have not been saved."
            alert.addButton(withTitle: "Save and Exit")
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            return action(for: alert.runModal(), primary: .saveAndExit, secondary: .discardAndExit)
        case .unsavedEffects:
            alert.messageText = "Effects state is not saved"
            alert.informativeText = "Retry saving, or exit and restore the on-disk state next time."
            alert.addButton(withTitle: "Retry")
            alert.addButton(withTitle: "Exit")
            alert.addButton(withTitle: "Cancel")
            return action(for: alert.runModal(), primary: .retry, secondary: .exit)
        case .unsavedNodesAndEffects:
            alert.messageText = "Save all changes before quitting?"
            alert.informativeText = "Preamp edits and the Effects state have not been saved."
            alert.addButton(withTitle: "Save and Exit")
            alert.addButton(withTitle: "Discard and Exit")
            alert.addButton(withTitle: "Cancel")
            return action(for: alert.runModal(), primary: .saveAndExit, secondary: .discardAndExit)
        case let .uncertainPersistence(generation):
            alert.messageText = "Configuration durability is uncertain"
            alert.informativeText = "Retry the final sync for generation \(generation), or exit without claiming which complete file is on disk."
            alert.addButton(withTitle: "Retry")
            alert.addButton(withTitle: "Exit")
            alert.addButton(withTitle: "Cancel")
            return action(for: alert.runModal(), primary: .retry, secondary: .exit)
        }
    }

    private func action(
        for response: NSApplication.ModalResponse,
        primary: M1TerminationAction,
        secondary: M1TerminationAction
    ) -> M1TerminationAction? {
        if response == .alertFirstButtonReturn { return primary }
        if response == .alertSecondButtonReturn { return secondary }
        return nil
    }
}

private final class M1RouteHolder: @unchecked Sendable {
    var route: M1NativeAudioRouteCoordinator?
    weak var controller: M1ProductController?
}

@main
struct EqualizerAUM1App: App {
    @NSApplicationDelegateAdaptor(M1TerminationDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
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
        WindowGroup("EqualizerAU", id: "editor") {
            M1EditorView(model: model)
                .onAppear {
                    appDelegate.model = model
                    appDelegate.restoreEditorWindow = {
                        if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) {
                            window.makeKeyAndOrderFront(nil)
                        } else {
                            openWindow(id: "editor")
                        }
                        NSApp.activate(ignoringOtherApps: true)
                    }
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
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }
                    .keyboardShortcut("z")
                    .disabled(!model.snapshot.canUndo)
                Button("Redo") { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.snapshot.canRedo)
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") { model.cut() }
                    .keyboardShortcut("x")
                    .disabled(!model.snapshot.canUseSelection)
                Button("Copy") { model.copy() }
                    .keyboardShortcut("c")
                    .disabled(!model.snapshot.canUseSelection)
                Button("Paste") { model.paste() }
                    .keyboardShortcut("v")
                    .disabled(!model.snapshot.canEdit)
                Button("Select All") { model.selectAll() }
                    .keyboardShortcut("a")
                    .disabled(!model.snapshot.canEdit)
            }
            CommandGroup(after: .pasteboard) {
                Button("Delete") { model.deleteSelection() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(!model.snapshot.canUseSelection)
            }
            CommandGroup(after: .textEditing) {
                Button("Move Focus Up") { model.moveFocus(by: -1, extending: false) }
                    .keyboardShortcut(.upArrow, modifiers: [])
                    .disabled(!model.snapshot.canEdit)
                Button("Move Focus Down") { model.moveFocus(by: 1, extending: false) }
                    .keyboardShortcut(.downArrow, modifiers: [])
                    .disabled(!model.snapshot.canEdit)
                Button("Extend Selection Up") { model.moveFocus(by: -1, extending: true) }
                    .keyboardShortcut(.upArrow, modifiers: [.shift])
                    .disabled(!model.snapshot.canEdit)
                Button("Extend Selection Down") { model.moveFocus(by: 1, extending: true) }
                    .keyboardShortcut(.downArrow, modifiers: [.shift])
                    .disabled(!model.snapshot.canEdit)
                Divider()
                Button("Move Selection Up") { model.moveSelection(by: -1) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .control])
                    .disabled(!model.snapshot.canUseSelection)
                Button("Move Selection Down") { model.moveSelection(by: 1) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .control])
                    .disabled(!model.snapshot.canUseSelection)
            }
            CommandMenu("Audio") {
                Button("Start Engine") { model.start() }
                    .disabled(!model.snapshot.canStart)
                Button("Stop Engine") { model.stop() }
                    .disabled(!model.snapshot.canStop)
                Divider()
                Button("Diagnostics Snapshot…") { model.presentDiagnostics() }
                    .disabled(model.snapshot.audio != .running)
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
            Button { model.save() } label: { Image(systemName: "square.and.arrow.down") }
                .help("Save configuration")
                .disabled(!model.snapshot.canSave)

            Toggle(
                "Processing",
                isOn: Binding(
                    get: { model.snapshot.processingEnabled },
                    set: { model.setProcessing($0) }
                )
            )
            .toggleStyle(.switch)
            .disabled(!model.snapshot.canSetProcessing)

            Spacer()

            if case .uncertain = model.snapshot.persistence {
                Button("Retry") { model.retryPersistence() }
            }
            if case .waitingForOutput = model.snapshot.persistence {
                Button("Retry Output") { model.retryOutput() }
            }
            if let layout = model.snapshot.outputLayout {
                Text("\(layout.channels.count) ch  \(Int(layout.sampleRate)) Hz")
                    .foregroundStyle(.secondary)
            } else {
                Text("No active output")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var chain: some View {
        List {
            ForEach(Array(model.snapshot.draft.nodes.enumerated()), id: \.element.id) { index, node in
                nodeRow(node, index: index)
                .contentShape(Rectangle())
                .onTapGesture {
                    model.select(node.id, mode: currentSelectionMode())
                }
                .listRowBackground(rowBackground(for: node.id))
                .onDrag { model.beginDrag(node.id) }
                .onDrop(
                    of: [m1NodeDragType],
                    delegate: M1NodeDropDelegate(model: model, destination: index)
                )
                .disabled(!model.snapshot.canEdit)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    Button("Channels") { model.addChannels(before: nil) }
                    Button("Preamp") { model.add(before: nil) }
                    Button("Graphic EQ") { model.addGraphicEQ(before: nil) }
                    Button("Convolution…") { model.importConvolution(before: nil) }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .disabled(!model.snapshot.canEdit)
                Spacer()
            }
            .padding(10)
            .background(.bar)
            .onDrop(
                of: [m1NodeDragType],
                delegate: M1NodeDropDelegate(
                    model: model,
                    destination: model.snapshot.draft.nodes.count
                )
            )
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: statusIcon)
                Text(statusText)
                Spacer()
            }
            if let diagnostics = model.snapshot.activeDiagnostics,
               let generation = model.snapshot.activeConfigurationGeneration {
                diagnosticLine(label: "Active G\(generation)", diagnostics: diagnostics)
            }
            if let diagnostics = model.snapshot.expectedDiagnostics,
               let generation = model.snapshot.expectedConfigurationGeneration {
                diagnosticLine(label: "Expected G\(generation)", diagnostics: diagnostics)
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
        switch model.snapshot.persistence {
        case .clean:
            if model.snapshot.audio == .running {
                return model.snapshot.appliedEffectsEnabled == true
                    ? "Processing active"
                    : "Processing bypassed"
            }
            return "Ready"
        case .modified: return "Unsaved changes"
        case let .saving(generation): return "Saving generation \(generation)…"
        case let .uncertain(generation): return "Generation \(generation) durability is uncertain"
        case .recovery: return "Configuration repair required"
        case .waitingForOutput: return "Saved; waiting for an output device"
        case .savedPendingStart: return "Saved; applies on next engine start"
        case let .pendingApplication(generation): return "Applying generation \(generation)…"
        case let .failed(reason): return reason
        }
    }

    @ViewBuilder
    private func diagnosticLine(
        label: String,
        diagnostics: M1ProcessingBuildDiagnostics
    ) -> some View {
        let details = diagnosticDetails(diagnostics)
        if !details.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(label).fontWeight(.semibold)
                Text(details.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func diagnosticDetails(_ diagnostics: M1ProcessingBuildDiagnostics) -> [String] {
        var details: [String] = []
        let unresolved = diagnostics.unresolvedChannels.flatMap(\.identifiers).map(\.rawValue)
        if !unresolved.isEmpty {
            details.append("Unresolved: \(unresolved.joined(separator: ", "))")
        }
        if !diagnostics.clippingRiskChannels.isEmpty {
            details.append(
                "Clipping risk: \(diagnostics.clippingRiskChannels.map(\.rawValue).joined(separator: ", "))"
            )
        }
        if !diagnostics.gainBoundaries.isEmpty {
            let channels = diagnostics.gainBoundaries.map { $0.channel.rawValue }
            details.append("Gain boundary: \(channels.joined(separator: ", "))")
        }
        if !diagnostics.unavailableGraphicEQBands.isEmpty {
            let frequencies = diagnostics.unavailableGraphicEQBands.map {
                formatFrequency($0.frequencyHz)
            }
            details.append("Above Nyquist: \(frequencies.joined(separator: ", "))")
        }
        return details
    }

    @ViewBuilder
    private func nodeRow(_ node: M1ProcessingNode, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                Image(systemName: nodeIcon(node.kind))
                Text(nodeTitle(node.kind))
                    .fontWeight(.medium)
                    .frame(width: 90, alignment: .leading)
                switch node.kind {
                case .channels:
                    Text(channelSummary(node.channels))
                        .foregroundStyle(.secondary)
                    if let warning = scopeDiagnosticSummary(node.id) {
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                case .preamp:
                    if !node.isEnabled {
                        Text("Disabled")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(channelSummary(effectiveSelections[node.id] ?? .all))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(node.gainDB.formatted(.number.precision(.fractionLength(1))))
                        .monospacedDigit()
                    Text("dB").foregroundStyle(.secondary)
                case .graphicEQ:
                    if !node.isEnabled {
                        Text("Disabled")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(channelSummary(effectiveSelections[node.id] ?? .all))
                        .foregroundStyle(.secondary)
                    if let warning = graphicEQDiagnosticSummary(node.id) {
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Text(graphicEQSummary(node.graphicEQBands))
                        .monospacedDigit()
                case .convolution:
                    convolutionSummary(node)
                }
                Spacer()
                Button { model.delete(node.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain)
                    .help("Delete node")
            }

            if model.snapshot.focusedNodeID == node.id {
                Divider()
                switch node.kind {
                case .channels:
                    channelEditor(node)
                case .preamp:
                    preampEditor(node)
                case .graphicEQ:
                    graphicEQEditor(node)
                case .convolution:
                    convolutionEditor(node)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func scopeDiagnosticSummary(_ nodeID: UUID) -> String? {
        let active = model.snapshot.activeDiagnostics?.unresolvedChannels
            .first { $0.nodeID == nodeID }?.identifiers.map(\.rawValue)
        let expected = model.snapshot.expectedDiagnostics?.unresolvedChannels
            .first { $0.nodeID == nodeID }?.identifiers.map(\.rawValue)
        var parts: [String] = []
        if let active, !active.isEmpty {
            parts.append("Active unresolved: \(active.joined(separator: ", "))")
        }
        if let expected, !expected.isEmpty {
            parts.append("Expected unresolved: \(expected.joined(separator: ", "))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func graphicEQDiagnosticSummary(_ nodeID: UUID) -> String? {
        let draft = model.snapshot.draft.nodes.first { $0.id == nodeID }.map {
            $0.graphicEQBands.filter(isGraphicEQBandUnavailable).map {
                formatFrequency($0.frequencyHz)
            }
        }
        let active = model.snapshot.activeDiagnostics?.unavailableGraphicEQBands
            .filter { $0.nodeID == nodeID }
            .map { formatFrequency($0.frequencyHz) }
        let expected = model.snapshot.expectedDiagnostics?.unavailableGraphicEQBands
            .filter { $0.nodeID == nodeID }
            .map { formatFrequency($0.frequencyHz) }
        var parts: [String] = []
        if let draft, !draft.isEmpty {
            parts.append("Draft unavailable: \(draft.joined(separator: ", "))")
        }
        if let active, !active.isEmpty {
            parts.append("Active unavailable: \(active.joined(separator: ", "))")
        }
        if let expected, !expected.isEmpty {
            parts.append("Expected unavailable: \(expected.joined(separator: ", "))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var effectiveSelections: [UUID: M1ChannelSelection] {
        M1ProcessingScopeResolver.effectiveSelections(nodes: model.snapshot.draft.nodes)
    }

    private func isGraphicEQBandUnavailable(_ band: M1GraphicEQBand) -> Bool {
        guard let sampleRate = model.snapshot.outputLayout?.sampleRate else { return false }
        return band.frequencyHz >= sampleRate / 2
    }

    private func preampEditor(_ node: M1ProcessingNode) -> some View {
        HStack(spacing: 10) {
            Toggle("Enabled", isOn: Binding(
                get: { node.isEnabled },
                set: { model.setEnabled($0, id: node.id) }
            ))
            Slider(
                value: Binding(
                    get: { node.gainDB },
                    set: { model.setGain($0, id: node.id) }
                ),
                in: -20...20,
                step: 0.1,
                onEditingChanged: { editing in
                    if editing { model.beginGesture(node.id) }
                    else { model.endGesture(node.id) }
                }
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
            .frame(width: 64)
            Text("dB").foregroundStyle(.secondary)
        }
    }

    private func graphicEQEditor(_ node: M1ProcessingNode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Enabled", isOn: Binding(
                get: { node.isEnabled },
                set: { model.setEnabled($0, id: node.id) }
            ))

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(Array(node.graphicEQBands.enumerated()), id: \.offset) { index, band in
                        let unavailable = isGraphicEQBandUnavailable(band)
                        VStack(spacing: 6) {
                            Text(formatFrequency(band.frequencyHz))
                                .font(.caption)
                                .foregroundStyle(unavailable ? .orange : .secondary)
                                .frame(width: 54)
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .opacity(unavailable ? 1 : 0)
                                .frame(height: 10)
                                .accessibilityHidden(true)
                            Slider(
                                value: Binding(
                                    get: { band.gainDB },
                                    set: { model.setGraphicEQGain($0, bandIndex: index, id: node.id) }
                                ),
                                in: M1GraphicEQContract.minimumGainDB...M1GraphicEQContract.maximumGainDB,
                                step: M1GraphicEQContract.gainStepDB,
                                onEditingChanged: { editing in
                                    if editing { model.beginGesture(node.id) }
                                    else { model.endGesture(node.id) }
                                }
                            )
                            .rotationEffect(.degrees(-90))
                            .frame(width: 112, height: 24)
                            .frame(width: 32, height: 112)
                            .accessibilityLabel(
                                "\(formatFrequency(band.frequencyHz)) gain"
                                    + (unavailable ? ", unavailable at current sample rate" : "")
                            )
                            TextField(
                                "Gain",
                                value: Binding(
                                    get: { band.gainDB },
                                    set: {
                                        let bounded = min(
                                            max($0, M1GraphicEQContract.minimumGainDB),
                                            M1GraphicEQContract.maximumGainDB
                                        )
                                        model.setGraphicEQGain(
                                            bounded,
                                            bandIndex: index,
                                            id: node.id
                                        )
                                    }
                                ),
                                format: .number.precision(.fractionLength(1))
                            )
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 54)
                            .accessibilityLabel(
                                "\(formatFrequency(band.frequencyHz)) gain in decibels"
                                    + (unavailable ? ", unavailable at current sample rate" : "")
                            )
                        }
                        .frame(width: 58)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.visible)
        }
    }

    private func convolutionSummary(_ node: M1ProcessingNode) -> some View {
        let ir = node.convolutionIR!
        return HStack(spacing: 8) {
            Text(node.isEnabled ? "Enabled" : "Disabled")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(channelSummary(effectiveSelections[node.id] ?? .all))
                .foregroundStyle(.secondary)
            Text(ir.originalFileName)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(Int(ir.sampleRate)) Hz · \(ir.channelCount) ch · \(ir.frameCount) frames")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func convolutionEditor(_ node: M1ProcessingNode) -> some View {
        let ir = node.convolutionIR!
        let duration = Double(ir.frameCount) / ir.sampleRate
        return VStack(alignment: .leading, spacing: 8) {
            Toggle("Enabled", isOn: Binding(
                get: { node.isEnabled },
                set: { model.setEnabled($0, id: node.id) }
            ))
            LabeledContent("Impulse response") {
                Text(ir.originalFileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            LabeledContent("Source") {
                Text("\(Int(ir.sampleRate)) Hz · \(ir.channelCount) ch · \(ir.frameCount) frames · \(duration.formatted(.number.precision(.fractionLength(3)))) s")
                    .lineLimit(1)
            }
            LabeledContent("Processing") {
                Text("0 frame algorithmic latency")
            }
            Button { model.replaceConvolutionIR(id: node.id) } label: {
                Label("Replace…", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("Replace impulse response")
        }
    }

    private func channelEditor(_ node: M1ProcessingNode) -> some View {
        HStack {
            Text("Apply following effects to")
                .foregroundStyle(.secondary)
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
                Divider()
                Button("Add Custom Channel…") { addCustomChannel(to: node) }
            } label: {
                Text(channelSummary(node.channels))
            }
        }
    }

    private func rowBackground(for id: UUID) -> some View {
        let selected = model.snapshot.selectedNodeIDs.contains(id)
        let focused = model.snapshot.focusedNodeID == id
        return ZStack {
            if selected { Color.accentColor.opacity(0.18) }
            if focused {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.accentColor, lineWidth: 1)
                    .padding(2)
            }
        }
    }

    private func currentSelectionMode() -> M1SelectionMode {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift) { return .extending }
        if modifiers.contains(.command) { return .toggling }
        return .replacing
    }

    private func addCustomChannel(to node: M1ProcessingNode) {
        let alert = NSAlert()
        alert.messageText = "Add Custom Channel"
        alert.informativeText = "Enter a non-empty channel identifier. It will be normalized to uppercase."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              let identifier = M1ChannelIdentifier(field.stringValue) else { return }
        model.setChannels(
            updatedChannels(node.channels, identifier: identifier, selected: true),
            id: node.id
        )
    }

    private func channelSummary(_ selection: M1ChannelSelection) -> String {
        switch selection {
        case .all: return "All"
        case let .identifiers(values): return values.map(\.rawValue).joined(separator: ", ")
        }
    }

    private func nodeIcon(_ kind: M1ProcessingNodeKind) -> String {
        switch kind {
        case .channels: return "speaker.wave.2"
        case .preamp: return "dial.medium"
        case .graphicEQ: return "slider.vertical.3"
        case .convolution: return "waveform.path"
        }
    }

    private func nodeTitle(_ kind: M1ProcessingNodeKind) -> String {
        switch kind {
        case .channels: return "Channels"
        case .preamp: return "Preamp"
        case .graphicEQ: return "Graphic EQ"
        case .convolution: return "Convolution"
        }
    }

    private func graphicEQSummary(_ bands: [M1GraphicEQBand]) -> String {
        let gains = bands.map(\.gainDB)
        guard let minimum = gains.min(), let maximum = gains.max(), minimum != 0 || maximum != 0 else {
            return "Flat"
        }
        return "\(minimum.formatted(.number.precision(.fractionLength(1))))…\(maximum.formatted(.number.precision(.fractionLength(1)))) dB"
    }

    private func formatFrequency(_ frequencyHz: Double) -> String {
        if frequencyHz >= 1_000 {
            let kilohertz = frequencyHz / 1_000
            return "\(kilohertz.formatted(.number.precision(.fractionLength(kilohertz == kilohertz.rounded() ? 0 : 1)))) kHz"
        }
        return "\(frequencyHz.formatted(.number.precision(.fractionLength(frequencyHz == frequencyHz.rounded() ? 0 : 1)))) Hz"
    }

    private func selectedIdentifiers(_ selection: M1ChannelSelection) -> [M1ChannelIdentifier] {
        if case let .identifiers(values) = selection { return values }
        return []
    }

    private func channelIdentifiers(for node: M1ProcessingNode) -> [M1ChannelIdentifier] {
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

@MainActor
private struct M1NodeDropDelegate: DropDelegate {
    let model: M1AppModel
    let destination: Int

    func validateDrop(info: DropInfo) -> Bool {
        model.snapshot.canEdit && info.hasItemsConforming(to: [m1NodeDragType])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: NSEvent.modifierFlags.contains(.option) ? .copy : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
        let operation: M1NodeDragOperation = NSEvent.modifierFlags.contains(.option) ? .copy : .move
        model.moveSelection(to: destination, operation: operation)
        return true
    }
}
