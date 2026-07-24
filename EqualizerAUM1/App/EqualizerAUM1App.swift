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
        audioRecovery: .inactive,
        outputLayout: nil,
        availableOutputLayout: nil,
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
    private var draggedNodeID: UUID?
    private let pasteboard: any M1PasteboardAccess
    private let audioLifecycleMonitor: (any M1AudioLifecycleMonitoring)?

    init(
        controller: M1ProductController,
        pasteboard: any M1PasteboardAccess = M1SystemPasteboard(),
        audioLifecycleMonitor: (any M1AudioLifecycleMonitoring)? = nil
    ) {
        self.controller = controller
        self.pasteboard = pasteboard
        self.audioLifecycleMonitor = audioLifecycleMonitor
    }

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        perform {
            await self.controller.bootstrap()
            try self.audioLifecycleMonitor?.start { [weak self] event in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await controller.handleAudioLifecycleEvent(event)
                    snapshot = await controller.snapshot()
                }
            }
        }
    }

    func applicationDidBecomeActive() {
        perform {
            await self.controller.handleApplicationActivation()
        }
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
        performEdit(onError: { self.presentConvolutionError($0, fileName: url.lastPathComponent) }) {
            let ir = try await Task.detached {
                try M1ConvolutionIRStore().importWAV(at: url)
            }.value
            try await self.controller.addConvolution(before: id, ir: ir)
        }
    }

    func replaceConvolutionIR(id: UUID) {
        guard let url = selectWAV() else { return }
        performEdit(onError: { self.presentConvolutionError($0, fileName: url.lastPathComponent) }) {
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

    func setGraphicEQGains(_ gains: [Double], id: UUID) {
        performEdit {
            try await self.controller.setGraphicEQGainsDB(id: id, gainsDB: gains)
        }
    }

    func setChannels(_ channels: M1ChannelSelection, id: UUID) {
        performEdit { try await self.controller.setChannels(id: id, channels: channels) }
    }

    func beginGesture(_ id: UUID) { performEdit { await self.controller.beginEditGesture(id) } }
    func endGesture(_ id: UUID) { performEdit { await self.controller.endEditGesture(id) } }
    func undo() {
        if routeTextHistory(redo: false) { return }
        guard snapshot.canUndo else { return }
        performEdit { try await self.controller.undo() }
    }
    func redo() {
        if routeTextHistory(redo: true) { return }
        guard snapshot.canRedo else { return }
        performEdit { try await self.controller.redo() }
    }
    func selectAll() {
        if routeTextCommand(#selector(NSText.selectAll(_:))) { return }
        performEdit { await self.controller.selectAllNodes() }
    }
    func moveFocus(by offset: Int, extending: Bool) {
        let selector = extending
            ? (offset < 0
                ? #selector(NSText.moveUpAndModifySelection(_:))
                : #selector(NSText.moveDownAndModifySelection(_:)))
            : (offset < 0 ? #selector(NSText.moveUp(_:)) : #selector(NSText.moveDown(_:)))
        if routeTextCommand(selector) { return }
        performEdit { await self.controller.moveSelectionFocus(by: offset, extending: extending) }
    }
    func selectFocused(toggling: Bool) {
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
            if !toggling {
                textView.insertText(" ", replacementRange: textView.selectedRange())
            }
            return
        }
        performEdit { await self.controller.selectFocusedNode(toggling: toggling) }
    }
    func deleteSelection() {
        if routeTextCommand(#selector(NSText.deleteBackward(_:))) { return }
        guard snapshot.canUseSelection else { return }
        performEdit { try await self.controller.deleteSelectedPreamps() }
    }
    func copy() {
        if routeTextCommand(#selector(NSText.copy(_:))) { return }
        guard snapshot.canUseSelection else { return }
        perform { try await self.controller.copySelection(to: self.pasteboard) }
    }
    func cut() {
        if routeTextCommand(#selector(NSText.cut(_:))) { return }
        guard snapshot.canUseSelection else { return }
        perform { try await self.controller.cutSelection(to: self.pasteboard) }
    }
    func paste() {
        if routeTextCommand(#selector(NSText.paste(_:))) { return }
        performEdit { try await self.controller.paste(from: self.pasteboard) }
    }
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
        draggedNodeID = id
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

    func moveDraggedSelection(to index: Int, operation: M1NodeDragOperation) {
        guard let draggedNodeID else { return }
        self.draggedNodeID = nil
        performEdit {
            try await self.controller.moveDraggedPreamps(
                startingAt: draggedNodeID,
                to: index,
                operation: operation
            )
        }
    }

    func cancelDrag() {
        draggedNodeID = nil
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

    private func presentConvolutionError(_ error: any Error, fileName: String) {
        let reason: String
        if let error = error as? M1ConvolutionIRError {
            switch error {
            case .fileTooLarge:
                reason = "The file exceeds the 32 MiB import limit."
            case .invalidWAV:
                reason = "The file is not a valid RIFF/WAVE file or is structurally damaged."
            case .unsupportedEncoding:
                reason = "The WAV encoding is unsupported. Use PCM 8/16/24/32-bit or Float32 audio."
            case .invalidMetadata:
                reason = "The WAV sample rate, channel count, or block metadata is invalid."
            case .emptyAudio:
                reason = "The WAV file contains no audio frames."
            case .durationExceeded:
                reason = "The impulse response exceeds the 2-second duration limit."
            case .invalidSample:
                reason = "The audio contains a non-finite, subnormal, or otherwise invalid sample."
            case .storageAlreadyExists:
                reason = "The imported resource conflicts with an existing stored impulse response."
            case .missingResource:
                reason = "The stored impulse-response resource is missing."
            case .hashMismatch:
                reason = "The stored impulse-response resource failed its integrity check."
            case .metadataMismatch:
                reason = "The stored impulse-response metadata no longer matches its audio data."
            case .resourceIO:
                reason = "The file or impulse-response storage could not be read or written."
            }
        } else {
            reason = "The impulse response could not be applied to the current configuration."
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unable to Import Impulse Response"
        alert.informativeText = "\(fileName) was not imported. \(reason) The existing configuration was not changed."
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
        audioLifecycleMonitor?.stop()
        try await controller.shutdown()
    }

    func requestTermination() async -> M1TerminationDecision {
        terminationPending = true
        await drainCommands()
        let decision = await controller.requestTermination()
        snapshot = await controller.snapshot()
        if case .terminate = decision {
            audioLifecycleMonitor?.stop()
        } else if case .stayOpen = decision {
            terminationPending = false
        }
        return decision
    }

    func resolveTermination(_ action: M1TerminationAction) async -> M1TerminationDecision {
        await drainCommands()
        let decision = await controller.resolveTermination(action)
        snapshot = await controller.snapshot()
        if case .terminate = decision {
            audioLifecycleMonitor?.stop()
        } else if case .stayOpen = decision {
            terminationPending = false
        }
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

    private func performEdit(
        onError: (@MainActor (any Error) -> Void)? = nil,
        _ operation: @escaping @MainActor () async throws -> Void
    ) {
        guard !terminationPending else { return }
        let predecessor = editTask
        commandSequence &+= 1
        editTask = Task {
            await predecessor?.value
            do {
                try await operation()
            } catch {
                if let onError {
                    onError(error)
                } else {
                    await controller.reportCommandError(String(describing: error))
                }
            }
            snapshot = await controller.snapshot()
        }
    }

    private func routeTextCommand(_ selector: Selector) -> Bool {
        guard NSApp.keyWindow?.firstResponder is NSTextView else { return false }
        return NSApp.sendAction(selector, to: nil, from: nil)
    }

    private func routeTextHistory(redo: Bool) -> Bool {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        guard let undoManager = textView.undoManager else { return true }
        if redo {
            if undoManager.canRedo { undoManager.redo() }
        } else if undoManager.canUndo {
            undoManager.undo()
        }
        return true
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

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        restoreEditorWindow?()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model?.applicationDidBecomeActive()
    }

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
        _model = StateObject(wrappedValue: M1AppModel(
            controller: controller,
            audioLifecycleMonitor: M1SystemAudioLifecycleMonitor()
        ))
    }

    var body: some Scene {
        Window("EqualizerAU", id: "editor") {
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
                    .disabled(!model.snapshot.canEdit)
                Button("Redo") { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.snapshot.canEdit)
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") { model.cut() }
                    .keyboardShortcut("x")
                    .disabled(!model.snapshot.canEdit)
                Button("Copy") { model.copy() }
                    .keyboardShortcut("c")
                    .disabled(!model.snapshot.canEdit)
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
                    .disabled(!model.snapshot.canEdit)
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
                Button("Add Focused Processor to Selection") {
                    model.selectFocused(toggling: false)
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!model.snapshot.canEdit)
                Button("Toggle Focused Processor Selection") {
                    model.selectFocused(toggling: true)
                }
                .keyboardShortcut(.space, modifiers: [.command])
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
    @State private var dropDestination: Int?
    @State private var editingGraphicEQNodeID: UUID?

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

            Menu {
                Button("Channels") { model.addChannels(before: nil) }
                Button("Preamp") { model.add(before: nil) }
                Button("Graphic EQ") { model.addGraphicEQ(before: nil) }
                Button("Convolution…") { model.importConvolution(before: nil) }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Add processor")
            .disabled(!model.snapshot.canEdit)

            Spacer()

            if case .uncertain = model.snapshot.persistence {
                Button("Retry") { model.retryPersistence() }
            }
            if case .waitingForOutput = model.snapshot.persistence {
                Button("Retry Output") { model.retryOutput() }
            }
            if model.snapshot.audioRecovery == .permissionRequired {
                Button("Open Audio Capture Settings") { openAudioCaptureSettings() }
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
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(model.snapshot.draft.nodes.enumerated()), id: \.element.id) { index, node in
                        nodeRow(node, index: index)
                            .id(node.id)
                            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                            .listRowBackground(rowBackground(for: node.id))
                            .overlay(alignment: .top) {
                                if dropDestination == index { insertionIndicator }
                            }
                            .overlay(alignment: .bottom) {
                                if index == model.snapshot.draft.nodes.count - 1,
                                   dropDestination == model.snapshot.draft.nodes.count {
                                    insertionIndicator
                                }
                            }
                            .onDrop(
                                of: [m1NodeDragType],
                                delegate: M1NodeDropDelegate(
                                    model: model,
                                    rowIndex: index,
                                    rowHeight: 58,
                                    endDestination: model.snapshot.draft.nodes.count,
                                    dropDestination: $dropDestination
                                )
                            )
                            .disabled(!model.snapshot.canEdit)
                    }

                    Color.clear
                        .frame(
                            maxWidth: .infinity,
                            minHeight: clearSelectionHeight(in: geometry.size.height)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { model.select(nil, mode: .replacing) }
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .accessibilityLabel("Clear processor selection")
                        .onDrop(
                            of: [m1NodeDragType],
                            delegate: M1NodeDropDelegate(
                                model: model,
                                rowIndex: nil,
                                rowHeight: clearSelectionHeight(in: geometry.size.height),
                                endDestination: model.snapshot.draft.nodes.count,
                                dropDestination: $dropDestination
                            )
                        )
                }
                .onChange(of: model.snapshot.focusedNodeID) { _, id in
                    if let id {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private func clearSelectionHeight(in listHeight: CGFloat) -> CGFloat {
        max(
            32,
            listHeight - CGFloat(model.snapshot.draft.nodes.count) * 58
        )
    }

    private var insertionIndicator: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(height: 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
        switch model.snapshot.audioRecovery {
        case .inactive:
            break
        case .suspendedForSleep:
            return "Audio suspended while the Mac sleeps"
        case let .recovering(_, attempt, maximumAttempts):
            return "Recovering audio route (\(attempt)/\(maximumAttempts))…"
        case .waitingForRetry:
            return "Automatic recovery paused; start Processing to retry"
        case .permissionRequired:
            return "System audio capture permission is required"
        }
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

    private func openAudioCaptureSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
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
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 34)
                .contentShape(Rectangle())
                .help("Move \(nodeTitle(node.kind))")
                .onDrag {
                    model.beginDrag(node.id)
                } preview: {
                    Color.clear.frame(width: 1, height: 1)
                }

            Text("\(index + 1)")
                .font(.body.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 34, alignment: .center)
                .allowsHitTesting(false)

            powerControl(node)

            Image(systemName: nodeIcon(node.kind))
                .frame(width: 20)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 2) {
                Text(nodeTitle(node.kind))
                    .fontWeight(.medium)
                Text(nodeSubtitle(node))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 104, alignment: .leading)
            .allowsHitTesting(false)

            nodeControls(node)
                .frame(maxWidth: .infinity, alignment: .trailing)

            Button { model.delete(node.id) } label: {
                Image(systemName: "trash")
                    .frame(width: 24, height: 28)
            }
            .buttonStyle(.plain)
            .help("Delete \(nodeTitle(node.kind))")
        }
        .frame(minHeight: 58)
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { selectRow(node.id) }
        }
        .opacity(node.isEnabled ? 1 : 0.58)
    }

    @ViewBuilder
    private func powerControl(_ node: M1ProcessingNode) -> some View {
        Button { model.setEnabled(!node.isEnabled, id: node.id) } label: {
            Image(systemName: "power")
                .foregroundStyle(node.isEnabled ? Color.accentColor : .secondary)
                .frame(width: 26, height: 30)
        }
        .buttonStyle(.plain)
        .help("\(node.isEnabled ? "Disable" : "Enable") \(nodeTitle(node.kind))")
        .accessibilityLabel("\(node.isEnabled ? "Disable" : "Enable") \(nodeTitle(node.kind))")
        .accessibilityValue(node.isEnabled ? "Enabled" : "Disabled")
    }

    @ViewBuilder
    private func nodeControls(_ node: M1ProcessingNode) -> some View {
        switch node.kind {
        case .channels:
            channelEditor(node)
        case .preamp:
            preampEditor(node)
        case .graphicEQ:
            graphicEQSummaryControl(node)
        case .convolution:
            convolutionEditor(node)
        }
    }

    private func nodeSubtitle(_ node: M1ProcessingNode) -> String {
        switch node.kind {
        case .channels:
            return scopeDiagnosticSummary(node.id) ?? "Scope for following processors"
        case .preamp, .graphicEQ, .convolution:
            return channelSummary(effectiveSelections[node.id] ?? .all) + " channels"
        }
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
        HStack(spacing: 8) {
            M1GainKnob(
                gainDB: node.gainDB,
                onChange: { model.setGain($0, id: node.id) },
                onEditingChanged: {
                    if $0 { model.beginGesture(node.id) }
                    else { model.endGesture(node.id) }
                }
            )
            M1GainTextField(
                gainDB: node.gainDB,
                onChange: { model.setGain($0, id: node.id) },
                onEditingChanged: {
                    if $0 { model.beginGesture(node.id) }
                    else { model.endGesture(node.id) }
                }
            )
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
            .frame(width: 64)
            Text("dB").foregroundStyle(.secondary)
        }
    }

    private func graphicEQSummaryControl(_ node: M1ProcessingNode) -> some View {
        HStack(spacing: 8) {
            if graphicEQDiagnosticSummary(node.id) != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(graphicEQDiagnosticSummary(node.id) ?? "")
            }
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(node.graphicEQBands.enumerated()), id: \.offset) { _, band in
                    Capsule()
                        .fill(isGraphicEQBandUnavailable(band) ? Color.orange : Color.accentColor)
                        .frame(width: 3, height: graphicEQBarHeight(band.gainDB))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)
            .accessibilityLabel("15-band Graphic EQ preview")
            Button { editingGraphicEQNodeID = node.id } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 24, height: 28)
            }
            .buttonStyle(.plain)
            .help("Edit Graphic EQ")
            .accessibilityLabel("Edit Graphic EQ")
            .popover(isPresented: graphicEQEditorPresentation(for: node.id), arrowEdge: .bottom) {
                graphicEQEditor(node)
                    .padding(12)
                    .frame(width: 620)
            }
        }
    }

    private func graphicEQEditorPresentation(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { editingGraphicEQNodeID == id },
            set: { presented in
                if presented { editingGraphicEQNodeID = id }
                else if editingGraphicEQNodeID == id { editingGraphicEQNodeID = nil }
            }
        )
    }

    private func graphicEQEditor(_ node: M1ProcessingNode) -> some View {
        M1GraphicEQEditor(
            bands: node.graphicEQBands,
            sampleRate: model.snapshot.outputLayout?.sampleRate,
            onCommit: { model.setGraphicEQGains($0, id: node.id) }
        )
    }

    private func graphicEQBarHeight(_ gainDB: Double) -> CGFloat {
        let normalized = min(max((gainDB + 24) / 48, 0), 1)
        return 6 + CGFloat(normalized) * 20
    }

    private func convolutionEditor(_ node: M1ProcessingNode) -> some View {
        let ir = node.convolutionIR!
        let duration = Double(ir.frameCount) / ir.sampleRate
        return HStack(spacing: 8) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(ir.originalFileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(ir.originalFileName)
                Text("\(Int(ir.sampleRate)) Hz · \(ir.channelCount) ch · \(duration.formatted(.number.precision(.fractionLength(3)))) s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            Button { model.replaceConvolutionIR(id: node.id) } label: {
                Image(systemName: "folder")
                    .frame(width: 24, height: 28)
            }
            .buttonStyle(.plain)
            .help("Replace impulse response")
            .accessibilityLabel("Replace impulse response")
        }
    }

    private func channelEditor(_ node: M1ProcessingNode) -> some View {
        let available = availableChannelIdentifiers
        let unavailable = selectedIdentifiers(node.channels).filter { !available.contains($0) }
        return HStack(spacing: 8) {
            Text(channelSummary(node.channels))
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Menu {
                Button("All") { model.setChannels(.all, id: node.id) }
                if available.isEmpty {
                    Text("No output channels available")
                        .foregroundStyle(.secondary)
                }
                ForEach(available, id: \.self) { identifier in
                    Toggle(
                        channelDisplayName(identifier),
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
                if !unavailable.isEmpty {
                    Divider()
                    Section("Unavailable in Current Output") {
                        ForEach(unavailable, id: \.self) { identifier in
                            Toggle(
                                channelDisplayName(identifier),
                                isOn: Binding(
                                    get: { selectedIdentifiers(node.channels).contains(identifier) },
                                    set: { selected in
                                        model.setChannels(
                                            updatedChannels(
                                                node.channels,
                                                identifier: identifier,
                                                selected: selected
                                            ),
                                            id: node.id
                                        )
                                    }
                                )
                            )
                        }
                    }
                }
            } label: {
                Text("Change…")
            }
            .fixedSize()
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

    private func selectRow(_ id: UUID) {
        model.select(id, mode: currentSelectionMode())
    }

    private func channelSummary(_ selection: M1ChannelSelection) -> String {
        switch selection {
        case .all: return "All"
        case let .identifiers(values): return values.map(channelDisplayName).joined(separator: ", ")
        }
    }

    private func channelDisplayName(_ identifier: M1ChannelIdentifier) -> String {
        guard let channel = Int(identifier.rawValue), channel > 0 else { return identifier.rawValue }
        return "Channel \(channel)"
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

    private var availableChannelIdentifiers: [M1ChannelIdentifier] {
        (model.snapshot.availableOutputLayout?.channels ?? []).map(\.identifier)
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

private struct M1GainTextField: View {
    let gainDB: Double
    let onChange: (Double) -> Void
    let onEditingChanged: (Bool) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Gain", text: $text)
            .focused($isFocused)
            .onAppear { text = formatted(gainDB) }
            .onChange(of: gainDB) { _, value in
                if !isFocused { text = formatted(value) }
            }
            .onChange(of: text) { _, value in
                guard isFocused, let parsed = parsed(value) else { return }
                onChange(min(max(parsed, -100), 100))
            }
            .onChange(of: isFocused) { wasFocused, focused in
                if focused {
                    text = formatted(gainDB)
                    onEditingChanged(true)
                } else if wasFocused {
                    normalizeText()
                    onEditingChanged(false)
                }
            }
            .onSubmit { isFocused = false }
    }

    private func normalizeText() {
        let value = parsed(text).map { min(max($0, -100), 100) } ?? gainDB
        onChange(value)
        text = formatted(value)
    }

    private func parsed(_ value: String) -> Double? {
        let decimalSeparator = Locale.current.decimalSeparator ?? "."
        return Double(
            value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: decimalSeparator, with: ".")
        )
    }

    private func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }
}

private struct M1GraphicEQEditor: View {
    let bands: [M1GraphicEQBand]
    let sampleRate: Double?
    let onCommit: ([Double]) -> Void

    private let initialGains: [Double]
    @State private var gains: [Double]
    @State private var didCommit = false

    init(
        bands: [M1GraphicEQBand],
        sampleRate: Double?,
        onCommit: @escaping ([Double]) -> Void
    ) {
        self.bands = bands
        self.sampleRate = sampleRate
        self.onCommit = onCommit
        initialGains = bands.map(\.gainDB)
        _gains = State(initialValue: initialGains)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Graphic EQ")
                .font(.headline)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 8) {
                    ForEach(bands.indices, id: \.self) { index in
                        let band = bands[index]
                        let unavailable = isUnavailable(band)
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
                            M1GraphicEQFader(gainDB: gainBinding(at: index))
                                .frame(width: 32, height: 112)
                                .accessibilityLabel(
                                    "\(formatFrequency(band.frequencyHz)) gain"
                                        + (unavailable ? ", unavailable at current sample rate" : "")
                                )
                            TextField(
                                "Gain",
                                value: gainBinding(at: index),
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
                .padding(.top, 2)
                .padding(.bottom, 18)
            }
            .scrollIndicators(.visible)
        }
        .onDisappear(perform: commitIfNeeded)
    }

    private func gainBinding(at index: Int) -> Binding<Double> {
        Binding(
            get: { gains[index] },
            set: { gains[index] = quantized($0) }
        )
    }

    private func commitIfNeeded() {
        guard !didCommit else { return }
        didCommit = true
        guard gains != initialGains else { return }
        onCommit(gains)
    }

    private func isUnavailable(_ band: M1GraphicEQBand) -> Bool {
        guard let sampleRate else { return false }
        return band.frequencyHz >= sampleRate / 2
    }

    private func formatFrequency(_ frequencyHz: Double) -> String {
        if frequencyHz >= 1_000 {
            let kilohertz = frequencyHz / 1_000
            return "\(kilohertz.formatted(.number.precision(.fractionLength(kilohertz == kilohertz.rounded() ? 0 : 1)))) kHz"
        }
        return "\(frequencyHz.formatted(.number.precision(.fractionLength(frequencyHz == frequencyHz.rounded() ? 0 : 1)))) Hz"
    }

    private func quantized(_ gain: Double) -> Double {
        let bounded = min(
            max(gain, M1GraphicEQContract.minimumGainDB),
            M1GraphicEQContract.maximumGainDB
        )
        return (bounded / M1GraphicEQContract.gainStepDB).rounded()
            * M1GraphicEQContract.gainStepDB
    }
}

private struct M1GraphicEQFader: View {
    @Binding var gainDB: Double

    var body: some View {
        GeometryReader { geometry in
            let fraction = normalized(gainDB)
            ZStack {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 4)
                    .padding(.vertical, 6)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 4, height: max(4, (geometry.size.height - 12) * fraction))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 6)
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                    .frame(width: 16, height: 16)
                    .position(
                        x: geometry.size.width / 2,
                        y: 6 + (geometry.size.height - 12) * (1 - fraction)
                    )
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        gainDB = gain(at: value.location.y, height: geometry.size.height)
                    }
            )
        }
        .accessibilityElement()
        .accessibilityValue("\(gainDB.formatted(.number.precision(.fractionLength(1)))) dB")
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment
                ? M1GraphicEQContract.gainStepDB
                : -M1GraphicEQContract.gainStepDB
            gainDB = quantized(gainDB + delta)
        }
    }

    private func gain(at y: CGFloat, height: CGFloat) -> Double {
        guard height > 12 else { return gainDB }
        let fraction = 1 - min(max(Double(y - 6) / Double(height - 12), 0), 1)
        let range = M1GraphicEQContract.maximumGainDB - M1GraphicEQContract.minimumGainDB
        return quantized(M1GraphicEQContract.minimumGainDB + fraction * range)
    }

    private func normalized(_ gain: Double) -> Double {
        let range = M1GraphicEQContract.maximumGainDB - M1GraphicEQContract.minimumGainDB
        return (min(max(gain, M1GraphicEQContract.minimumGainDB), M1GraphicEQContract.maximumGainDB)
            - M1GraphicEQContract.minimumGainDB) / range
    }

    private func quantized(_ gain: Double) -> Double {
        let bounded = min(
            max(gain, M1GraphicEQContract.minimumGainDB),
            M1GraphicEQContract.maximumGainDB
        )
        return (bounded / M1GraphicEQContract.gainStepDB).rounded()
            * M1GraphicEQContract.gainStepDB
    }
}

private struct M1GainKnob: View {
    let gainDB: Double
    let onChange: (Double) -> Void
    let onEditingChanged: (Bool) -> Void

    @State private var isDragging = false

    var body: some View {
        let boundedGain = min(max(gainDB, -20), 20)
        let angle = Angle.degrees((boundedGain / 20) * 135)
        ZStack {
            Circle()
                .fill(Color(nsColor: .controlBackgroundColor))
            Circle()
                .stroke(Color.secondary.opacity(0.45), lineWidth: 1)
            Capsule()
                .fill(Color.primary)
                .frame(width: 2, height: 9)
                .offset(y: -7)
                .rotationEffect(angle)
        }
        .frame(width: 32, height: 32)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        onEditingChanged(true)
                    }
                    let x = Double(value.location.x - 16)
                    let y = Double(value.location.y - 16)
                    guard hypot(x, y) >= 4 else { return }
                    let degrees = atan2(x, -y) * 180 / Double.pi
                    let boundedDegrees = min(max(degrees, -135), 135)
                    onChange(((boundedDegrees / 135) * 200).rounded() / 10)
                }
                .onEnded { _ in
                    isDragging = false
                    onEditingChanged(false)
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Preamp gain")
        .accessibilityValue("\(gainDB.formatted(.number.precision(.fractionLength(1)))) dB")
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 0.1 : -0.1
            onChange(min(max(gainDB + delta, -20), 20))
        }
    }
}

@MainActor
private struct M1NodeDropDelegate: DropDelegate {
    let model: M1AppModel
    let rowIndex: Int?
    let rowHeight: CGFloat
    let endDestination: Int
    @Binding var dropDestination: Int?

    func validateDrop(info: DropInfo) -> Bool {
        model.snapshot.canEdit && info.hasItemsConforming(to: [m1NodeDragType])
    }

    func dropEntered(info: DropInfo) {
        dropDestination = destination(for: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dropDestination = destination(for: info)
        return DropProposal(operation: NSEvent.modifierFlags.contains(.option) ? .copy : .move)
    }

    func dropExited(info: DropInfo) {
        dropDestination = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
        let operation: M1NodeDragOperation = NSEvent.modifierFlags.contains(.option) ? .copy : .move
        let destination = destination(for: info)
        dropDestination = nil
        model.moveDraggedSelection(to: destination, operation: operation)
        return true
    }

    private func destination(for info: DropInfo) -> Int {
        guard let rowIndex else { return endDestination }
        return info.location.y < rowHeight / 2 ? rowIndex : rowIndex + 1
    }
}
