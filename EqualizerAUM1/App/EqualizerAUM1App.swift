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
    private var editFailureSequence: UInt64 = 0
    private var acknowledgedEditFailureSequence: UInt64 = 0
    private var latestEditError: String?
    private var draggedNodeID: UUID?
    let pendingEditorCommitCoordinator = M1PendingEditorCommitCoordinator()
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

    func setGraphicEQPoints(_ points: [M1GraphicEQPoint], id: UUID) {
        performEdit {
            try await self.controller.setGraphicEQPoints(id: id, points: points)
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
        pendingEditorCommitCoordinator.commitPendingEditor()
        terminationPending = true
        await drainCommands()
        if editFailureSequence != acknowledgedEditFailureSequence {
            acknowledgedEditFailureSequence = editFailureSequence
            terminationPending = false
            return .stayOpen(latestEditError ?? "An editor change could not be applied")
        }
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
            _ = await predecessor?.value
            var currentError: String?
            do {
                try await operation()
            } catch {
                let message = String(describing: error)
                currentError = message
                if let onError {
                    onError(error)
                } else {
                    await controller.reportCommandError(message)
                }
            }
            snapshot = await controller.snapshot()
            if let currentError {
                editFailureSequence &+= 1
                latestEditError = currentError
            }
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

private struct M1GraphicEQSelectAllActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private extension FocusedValues {
    var m1GraphicEQSelectAllAction: (() -> Void)? {
        get { self[M1GraphicEQSelectAllActionKey.self] }
        set { self[M1GraphicEQSelectAllActionKey.self] = newValue }
    }
}

@main
struct EqualizerAUM1App: App {
    @NSApplicationDelegateAdaptor(M1TerminationDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model: M1AppModel
    @FocusedValue(\.m1GraphicEQSelectAllAction) private var graphicEQSelectAllAction

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

    private func performTextAction(_ action: Selector) -> Bool {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else {
            return false
        }
        return textView.tryToPerform(action, with: nil)
    }

    private func performTextUndo(isRedo: Bool) -> Bool {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
              let undoManager = textView.undoManager else {
            return false
        }
        if isRedo {
            guard undoManager.canRedo else { return false }
            undoManager.redo()
        } else {
            guard undoManager.canUndo else { return false }
            undoManager.undo()
        }
        return true
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
                Button("Undo") {
                    if !performTextUndo(isRedo: false) { model.undo() }
                }
                    .keyboardShortcut("z")
                    .disabled(!model.snapshot.canEdit)
                Button("Redo") {
                    if !performTextUndo(isRedo: true) { model.redo() }
                }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.snapshot.canEdit)
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") {
                    if !performTextAction(#selector(NSText.cut(_:))) { model.cut() }
                }
                    .keyboardShortcut("x")
                    .disabled(!model.snapshot.canEdit)
                Button("Copy") {
                    if !performTextAction(#selector(NSText.copy(_:))) { model.copy() }
                }
                    .keyboardShortcut("c")
                    .disabled(!model.snapshot.canEdit)
                Button("Paste") {
                    if !performTextAction(#selector(NSText.paste(_:))) { model.paste() }
                }
                    .keyboardShortcut("v")
                    .disabled(!model.snapshot.canEdit)
                Button("Select All") {
                    if performTextAction(#selector(NSText.selectAll(_:))) { return }
                    if let graphicEQSelectAllAction { graphicEQSelectAllAction() }
                    else { model.selectAll() }
                }
                    .keyboardShortcut("a")
                    .disabled(!model.snapshot.canEdit)
            }
            CommandGroup(after: .pasteboard) {
                Button("Delete") {
                    if !performTextAction(#selector(NSText.deleteBackward(_:))) {
                        model.deleteSelection()
                    }
                }
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
        if !diagnostics.graphicEQResolution.isEmpty {
            let errors = diagnostics.graphicEQResolution.map {
                "\(formatError($0.maximumErrorDB)) max / \(formatError($0.percentile99ErrorDB)) p99"
            }
            details.append("Graphic EQ FIR resolution: \(errors.joined(separator: ", "))")
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
        let active = model.snapshot.activeDiagnostics?.graphicEQResolution
            .first { $0.nodeID == nodeID }
        let expected = model.snapshot.expectedDiagnostics?.graphicEQResolution
            .first { $0.nodeID == nodeID }
        var parts: [String] = []
        if let active {
            parts.append(
                "Active FIR error: \(formatError(active.maximumErrorDB)) max, "
                    + "\(formatError(active.percentile99ErrorDB)) p99"
            )
        }
        if let expected {
            parts.append(
                "Expected FIR error: \(formatError(expected.maximumErrorDB)) max, "
                    + "\(formatError(expected.percentile99ErrorDB)) p99"
            )
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func formatError(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(2)))) dB"
    }

    private var effectiveSelections: [UUID: M1ChannelSelection] {
        M1ProcessingScopeResolver.effectiveSelections(nodes: model.snapshot.draft.nodes)
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
            M1GraphicEQMiniCurve(points: node.graphicEQPoints)
                .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)
                .accessibilityLabel(
                    "Graphic EQ target curve, \(node.graphicEQPoints.count) control points"
                )
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
                    .frame(width: 760, height: 520)
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
            points: node.graphicEQPoints,
            sampleRate: model.snapshot.outputLayout?.sampleRate,
            pendingCommitCoordinator: model.pendingEditorCommitCoordinator,
            onCommit: { model.setGraphicEQPoints($0, id: node.id) }
        )
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

private enum M1GraphicEQPlot {
    static func x(for frequencyHz: Double, width: CGFloat) -> CGFloat {
        let lower = log(M1GraphicEQContract.minimumFrequencyHz)
        let upper = log(M1GraphicEQContract.maximumFrequencyHz)
        let position = (log(frequencyHz) - lower) / (upper - lower)
        return width * CGFloat(min(max(position, 0), 1))
    }

    static func y(for gainDB: Double, height: CGFloat) -> CGFloat {
        let range = M1GraphicEQContract.maximumGainDB - M1GraphicEQContract.minimumGainDB
        let position = (M1GraphicEQContract.maximumGainDB - gainDB) / range
        return height * CGFloat(min(max(position, 0), 1))
    }
}

private struct M1GraphicEQMiniCurve: View {
    let points: [M1GraphicEQPoint]

    var body: some View {
        Canvas { context, size in
            let processingPoints = M1ProcessingBuilder.graphicEQProcessingPoints(points)
            var path = Path()
            for index in 0...64 {
                let fraction = Double(index) / 64
                let frequency = exp(
                    log(M1GraphicEQContract.minimumFrequencyHz)
                        + (log(M1GraphicEQContract.maximumFrequencyHz)
                            - log(M1GraphicEQContract.minimumFrequencyHz)) * fraction
                )
                let gain = M1ProcessingBuilder.graphicEQGainDB(
                    frequencyHz: frequency,
                    points: processingPoints
                )
                let position = CGPoint(
                    x: M1GraphicEQPlot.x(for: frequency, width: size.width),
                    y: M1GraphicEQPlot.y(for: gain, height: size.height)
                )
                if index == 0 { path.move(to: position) }
                else { path.addLine(to: position) }
            }
            context.stroke(path, with: .color(.accentColor), lineWidth: 2)
        }
    }
}

private struct M1EditableGraphicEQPoint: Identifiable, Equatable {
    let id: UUID
    var frequencyHz: Double
    var gainDB: Double
    var frequencyText: String
    var gainText: String
    var isFrequencyTextDirty = false
    var isGainTextDirty = false

    init(point: M1GraphicEQPoint) {
        id = UUID()
        frequencyHz = point.frequencyHz
        gainDB = point.gainDB
        frequencyText = Self.formatted(point.frequencyHz)
        gainText = Self.formatted(point.gainDB)
    }

    var point: M1GraphicEQPoint {
        M1GraphicEQPoint(frequencyHz: frequencyHz, gainDB: gainDB)
    }

    mutating func synchronizeFrequencyText() {
        frequencyText = Self.formatted(frequencyHz)
        isFrequencyTextDirty = false
    }

    mutating func synchronizeGainText() {
        gainText = Self.formatted(gainDB)
        isGainTextDirty = false
    }

    private static func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...3)))
    }
}

private enum M1GraphicEQFocusedField: Hashable {
    case frequency(UUID)
    case gain(UUID)
}

private struct M1GraphicEQEditor: View {
    let sampleRate: Double?
    let pendingCommitCoordinator: M1PendingEditorCommitCoordinator
    let onCommit: ([M1GraphicEQPoint]) -> Void

    private let initialPoints: [M1GraphicEQPoint]
    @State private var editablePoints: [M1EditableGraphicEQPoint]
    @State private var selectedPointIDs: Set<UUID> = []
    @State private var validationMessage: String?
    @State private var preview: M1GraphicEQPreview?
    @State private var previewTask: Task<Void, Never>?
    @State private var commitRegistrationID: UUID?
    @FocusState private var focusedField: M1GraphicEQFocusedField?

    init(
        points: [M1GraphicEQPoint],
        sampleRate: Double?,
        pendingCommitCoordinator: M1PendingEditorCommitCoordinator,
        onCommit: @escaping ([M1GraphicEQPoint]) -> Void
    ) {
        self.sampleRate = sampleRate
        self.pendingCommitCoordinator = pendingCommitCoordinator
        self.onCommit = onCommit
        initialPoints = points
        _editablePoints = State(initialValue: points.map(M1EditableGraphicEQPoint.init))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Graphic EQ")
                    .font(.headline)
                Text("\(editablePoints.count) points")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 12) {
                VStack(spacing: 4) {
                    curvePreview
                        .frame(minWidth: 360, minHeight: 300)
                        .background(Color(nsColor: .textBackgroundColor))
                        .overlay(Rectangle().stroke(Color.secondary.opacity(0.35), lineWidth: 1))
                        .accessibilityLabel("Graphic EQ frequency response preview")
                    frequencyLabels
                }
                pointTable
                    .frame(width: 340)
            }
            statusMessage
        }
        .onAppear {
            commitRegistrationID = pendingCommitCoordinator.register {
                if let focusedField { commitField(focusedField) }
                commitIfNeeded()
            }
            schedulePreview()
        }
        .onDisappear {
            if let commitRegistrationID {
                pendingCommitCoordinator.unregister(commitRegistrationID)
                self.commitRegistrationID = nil
            }
            previewTask?.cancel()
            if let focusedField { commitField(focusedField) }
            commitIfNeeded()
        }
        .onChange(of: focusedField) { previous, current in
            guard previous != current, let previous else { return }
            commitField(previous)
        }
        .focusedValue(\.m1GraphicEQSelectAllAction, selectAll)
        .onDeleteCommand(perform: handleDeleteCommand)
        .onMoveCommand(perform: moveSelection)
    }

    private var curvePreview: some View {
        Canvas { context, size in
            for gain in stride(from: -24.0, through: 24.0, by: 12.0) {
                var grid = Path()
                let y = M1GraphicEQPlot.y(for: gain, height: size.height)
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(grid, with: .color(.secondary.opacity(gain == 0 ? 0.4 : 0.18)))
            }
            drawTargetCurve(context: &context, size: size)
            drawCompiledCurve(context: &context, size: size)
        }
    }

    private var frequencyLabels: some View {
        HStack {
            Text("20 Hz")
            Spacer()
            Text("100 Hz")
            Spacer()
            Text("1 kHz")
            Spacer()
            Text("10 kHz")
            Spacer()
            Text("20 kHz")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var statusMessage: some View {
        if let validationMessage {
            Text(validationMessage).foregroundStyle(.orange)
        } else if let preview, preview.maximumErrorDB > M1ProcessingBuilder.graphicEQMaximumResponseErrorDB
                    || preview.percentile99ErrorDB
                        > M1ProcessingBuilder.graphicEQPercentile99ResponseErrorDB {
            Text("FIR resolution: \(formatError(preview.maximumErrorDB)) max, "
                + "\(formatError(preview.percentile99ErrorDB)) p99")
                .foregroundStyle(.orange)
        } else if sampleRate == nil {
            Text("Target response only")
                .foregroundStyle(.secondary)
                .help("The compiled FIR response requires the output device's sample rate.")
        }
    }

    private var pointTable: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text("Select").frame(width: 34)
                Text("Frequency (Hz)").frame(width: 140, alignment: .leading)
                Text("Gain (dB)").frame(width: 120, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(editablePoints) { point in
                        HStack(spacing: 6) {
                            Button { selectRow(point.id) } label: {
                                Image(systemName: selectedPointIDs.contains(point.id)
                                    ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 18, weight: .medium))
                                    .frame(width: 30, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .frame(width: 34, height: 30)
                            .help(selectedPointIDs.contains(point.id)
                                ? "Deselect this point" : "Select this point")
                            .accessibilityLabel(selectedPointIDs.contains(point.id)
                                ? "Deselect control point" : "Select control point")

                            TextField(
                                "Frequency",
                                text: frequencyTextBinding(for: point.id)
                            )
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .frequency(point.id))
                            .onSubmit { focusedField = nil }
                            .frame(width: 140)

                            TextField(
                                "Gain",
                                text: gainTextBinding(for: point.id)
                            )
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .gain(point.id))
                            .onSubmit { focusedField = nil }
                            .multilineTextAlignment(.leading)
                            .frame(width: 120)
                        }
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(selectedPointIDs.contains(point.id)
                            ? Color.accentColor.opacity(0.12) : Color.clear)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(Rectangle().stroke(Color.secondary.opacity(0.35), lineWidth: 1))

            HStack(spacing: 8) {
                toolButton("plus", "Add point", addPoint)
                    .disabled(editablePoints.count == M1GraphicEQContract.maximumPointCount)
                toolButton("minus", "Delete selected points", deleteSelected)
                    .disabled(selectedPointIDs.isEmpty)
                Button("Select All", action: selectAll)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Select every point")
                Button("Invert Selection", action: invertSelection)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Select unselected points and deselect selected points")
                Spacer()
                toolButton("square.and.arrow.down", "Import", importCSV)
                toolButton("square.and.arrow.up", "Export", exportCSV)
            }
            .buttonStyle(.borderless)

            HStack(spacing: 6) {
                labeledActionButton(
                    "plus.forwardslash.minus",
                    "Invert Gain",
                    "Invert the gain of every point",
                    invertResponse
                )
                labeledActionButton(
                    "arrow.up.to.line",
                    "Normalize Peak",
                    "Move the highest gain to 0 dB",
                    normalizeResponse
                )
                labeledActionButton(
                    "0.circle",
                    selectedPointIDs.isEmpty ? "Reset All" : "Reset Selected",
                    selectedPointIDs.isEmpty
                        ? "Reset every point to 0 dB"
                        : "Reset selected points to 0 dB",
                    resetSelection
                )
            }
            .controlSize(.small)
            .disabled(editablePoints.isEmpty)
        }
    }

    private func toolButton(
        _ systemName: String,
        _ help: String,
        _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .help(help)
    }

    private func labeledActionButton(
        _ systemName: String,
        _ title: String,
        _ help: String,
        _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemName)
                .frame(maxWidth: .infinity)
        }
        .help(help)
    }

    private func drawTargetCurve(context: inout GraphicsContext, size: CGSize) {
        var path = Path()
        let processingPoints = M1ProcessingBuilder.graphicEQProcessingPoints(modelPoints)
        for index in 0...256 {
            let fraction = Double(index) / 256
            let frequency = exp(
                log(M1GraphicEQContract.minimumFrequencyHz)
                    + (log(M1GraphicEQContract.maximumFrequencyHz)
                        - log(M1GraphicEQContract.minimumFrequencyHz)) * fraction
            )
            let gain = M1ProcessingBuilder.graphicEQGainDB(
                frequencyHz: frequency,
                points: processingPoints
            )
            let position = CGPoint(
                x: M1GraphicEQPlot.x(for: frequency, width: size.width),
                y: M1GraphicEQPlot.y(for: gain, height: size.height)
            )
            if index == 0 { path.move(to: position) }
            else { path.addLine(to: position) }
        }
        context.stroke(path, with: .color(.accentColor), lineWidth: 2)
    }

    private func drawCompiledCurve(context: inout GraphicsContext, size: CGSize) {
        guard let preview else { return }
        var path = Path()
        for index in preview.frequenciesHz.indices {
            let position = CGPoint(
                x: M1GraphicEQPlot.x(for: preview.frequenciesHz[index], width: size.width),
                y: M1GraphicEQPlot.y(for: preview.compiledGainDB[index], height: size.height)
            )
            if index == 0 { path.move(to: position) }
            else { path.addLine(to: position) }
        }
        context.stroke(
            path,
            with: .color(.orange),
            style: StrokeStyle(lineWidth: 1.25, dash: [5, 3])
        )
    }

    private var modelPoints: [M1GraphicEQPoint] {
        editablePoints.map(\.point).sorted { $0.frequencyHz < $1.frequencyHz }
    }

    private func addPoint() {
        guard editablePoints.count < M1GraphicEQContract.maximumPointCount else { return }
        let frequencies = Array(Set(
            [M1GraphicEQContract.minimumFrequencyHz]
                + editablePoints.map(\.frequencyHz).filter {
                    $0 > M1GraphicEQContract.minimumFrequencyHz
                        && $0 < M1GraphicEQContract.maximumFrequencyHz
                }
                + [M1GraphicEQContract.maximumFrequencyHz]
        )).sorted()
        let pair = zip(frequencies, frequencies.dropFirst()).max {
            log($0.1 / $0.0) < log($1.1 / $1.0)
        }
        guard let pair, pair.0 < pair.1 else { return }
        var frequency = sqrt(pair.0 * pair.1)
        while editablePoints.contains(where: { $0.frequencyHz == frequency }) {
            frequency = min(frequency + 0.1, M1GraphicEQContract.maximumFrequencyHz)
        }
        let point = M1EditableGraphicEQPoint(point: M1GraphicEQPoint(
            frequencyHz: frequency,
            gainDB: M1ProcessingBuilder.graphicEQProcessingGainDB(
                frequencyHz: frequency,
                points: modelPoints
            )
        ))
        editablePoints.append(point)
        editablePoints.sort { $0.frequencyHz < $1.frequencyHz }
        selectedPointIDs = [point.id]
        validationMessage = nil
        schedulePreview()
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        do {
            let texts = try panel.urls.map { try String(contentsOf: $0, encoding: .utf8) }
            let points = try M1GraphicEQCSVCodec.decode(texts)
            editablePoints = points.map(M1EditableGraphicEQPoint.init)
            selectedPointIDs.removeAll()
            validationMessage = nil
            schedulePreview()
        } catch M1GraphicEQCSVCodecError.invalidPoints {
            validationMessage = "Imported points violate the Graphic EQ range or uniqueness contract."
        } catch {
            validationMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "graphic-eq.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = M1GraphicEQCSVCodec.encode(modelPoints)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            validationMessage = nil
        } catch {
            validationMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func invertResponse() {
        for index in editablePoints.indices {
            editablePoints[index].gainDB = -editablePoints[index].gainDB
            editablePoints[index].synchronizeGainText()
        }
        validationMessage = nil
        schedulePreview()
    }

    private func normalizeResponse() {
        guard let maximum = editablePoints.map(\.gainDB).max(), maximum != 0 else { return }
        let candidate = editablePoints.map { point -> M1EditableGraphicEQPoint in
            var point = point
            point.gainDB -= maximum
            point.synchronizeGainText()
            return point
        }
        guard candidate.allSatisfy({ $0.gainDB >= M1GraphicEQContract.minimumGainDB }) else {
            validationMessage = "Normalization would exceed -24 dB."
            return
        }
        editablePoints = candidate
        validationMessage = nil
        schedulePreview()
    }

    private func frequencyTextBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { editablePoints.first(where: { $0.id == id })?.frequencyText ?? "" },
            set: { text in
                guard let index = editablePoints.firstIndex(where: { $0.id == id }) else { return }
                editablePoints[index].frequencyText = text
                editablePoints[index].isFrequencyTextDirty = true
            }
        )
    }

    private func gainTextBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { editablePoints.first(where: { $0.id == id })?.gainText ?? "" },
            set: { text in
                guard let index = editablePoints.firstIndex(where: { $0.id == id }) else { return }
                editablePoints[index].gainText = text
                editablePoints[index].isGainTextDirty = true
            }
        )
    }

    private func commitField(_ field: M1GraphicEQFocusedField) {
        switch field {
        case let .frequency(id):
            guard let index = editablePoints.firstIndex(where: { $0.id == id }),
                  editablePoints[index].isFrequencyTextDirty else { return }
            let text = editablePoints[index].frequencyText
            guard let value = parseNumber(text), value.isFinite, value > 0,
                  !editablePoints.contains(where: {
                      $0.id != id && $0.frequencyHz == value
                  }) else {
                editablePoints[index].synchronizeFrequencyText()
                validationMessage = "Frequency must be positive, finite, and unique."
                return
            }
            let changed = editablePoints[index].frequencyHz != value
            editablePoints[index].frequencyHz = value
            editablePoints[index].synchronizeFrequencyText()
            editablePoints.sort { $0.frequencyHz < $1.frequencyHz }
            validationMessage = nil
            if changed { schedulePreview() }

        case let .gain(id):
            guard let index = editablePoints.firstIndex(where: { $0.id == id }),
                  editablePoints[index].isGainTextDirty else { return }
            let text = editablePoints[index].gainText
            guard let value = parseNumber(text), value.isFinite,
                  value >= M1GraphicEQContract.minimumGainDB,
                  value <= M1GraphicEQContract.maximumGainDB else {
                editablePoints[index].synchronizeGainText()
                validationMessage = "Gain must be between -24 and +24 dB."
                return
            }
            let changed = editablePoints[index].gainDB != value
            editablePoints[index].gainDB = value
            editablePoints[index].synchronizeGainText()
            validationMessage = nil
            if changed { schedulePreview() }
        }
    }

    private func parseNumber(_ text: String) -> Double? {
        try? FloatingPointFormatStyle<Double>.number.parseStrategy.parse(text)
    }

    private func handleDeleteCommand() {
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
            textView.deleteBackward(nil)
        } else {
            deleteSelected()
        }
    }

    private func deleteSelected() {
        guard !selectedPointIDs.isEmpty else { return }
        editablePoints.removeAll { selectedPointIDs.contains($0.id) }
        selectedPointIDs.removeAll()
        validationMessage = nil
        schedulePreview()
    }

    private func selectAll() {
        selectedPointIDs = Set(editablePoints.map(\.id))
    }

    private func invertSelection() {
        selectedPointIDs = Set(editablePoints.map(\.id)).subtracting(selectedPointIDs)
    }

    private func selectRow(_ id: UUID) {
        if selectedPointIDs.contains(id) {
            selectedPointIDs.remove(id)
        } else {
            selectedPointIDs.insert(id)
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
            let action: Selector
            switch direction {
            case .up: action = #selector(NSText.moveUp(_:))
            case .down: action = #selector(NSText.moveDown(_:))
            case .left: action = #selector(NSText.moveLeft(_:))
            case .right: action = #selector(NSText.moveRight(_:))
            @unknown default: return
            }
            _ = textView.tryToPerform(action, with: nil)
            return
        }
        guard !selectedPointIDs.isEmpty else { return }
        var candidate = editablePoints
        for index in candidate.indices where selectedPointIDs.contains(candidate[index].id) {
            switch direction {
            case .up:
                candidate[index].gainDB += 1
            case .down:
                candidate[index].gainDB -= 1
            case .left:
                candidate[index].frequencyHz -= 1
            case .right:
                candidate[index].frequencyHz += 1
            @unknown default:
                return
            }
        }
        candidate.sort { $0.frequencyHz < $1.frequencyHz }
        guard candidate.allSatisfy({
            $0.frequencyHz > 0
                && $0.gainDB >= M1GraphicEQContract.minimumGainDB
                && $0.gainDB <= M1GraphicEQContract.maximumGainDB
        }), zip(candidate, candidate.dropFirst()).allSatisfy({ $0.0.frequencyHz < $0.1.frequencyHz })
        else {
            validationMessage = "The keyboard adjustment would exceed a range or duplicate a frequency."
            return
        }
        editablePoints = candidate.map { point in
            var point = point
            point.synchronizeFrequencyText()
            point.synchronizeGainText()
            return point
        }
        validationMessage = nil
        schedulePreview()
    }

    private func resetSelection() {
        let targets = selectedPointIDs.isEmpty
            ? Set(editablePoints.map(\.id))
            : selectedPointIDs
        for index in editablePoints.indices where targets.contains(editablePoints[index].id) {
            editablePoints[index].gainDB = 0
            editablePoints[index].synchronizeGainText()
        }
        validationMessage = nil
        schedulePreview()
    }

    private func schedulePreview() {
        previewTask?.cancel()
        guard let sampleRate else {
            preview = nil
            return
        }
        let points = modelPoints
        previewTask = Task.detached(priority: .userInitiated) {
            do {
                try await Task.sleep(for: .milliseconds(120))
                try Task.checkCancellation()
                let result = try M1ProcessingBuilder.graphicEQPreview(
                    points: points,
                    sampleRate: sampleRate
                )
                try Task.checkCancellation()
                await MainActor.run { preview = result }
            } catch {}
        }
    }

    private func commitIfNeeded() {
        let points = modelPoints
        guard points != initialPoints else { return }
        onCommit(points)
    }

    private func formatError(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(2)))) dB"
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
