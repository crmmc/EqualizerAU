import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

protocol M1AudioLifecycleMonitoring: AnyObject {
    func start(handler: @escaping @Sendable (M1AudioLifecycleEvent) -> Void) throws
    func stop()
}

@MainActor
protocol M1TextCommandRouting {
    func route(_ selector: Selector) -> Bool
    func routeHistory(redo: Bool) -> Bool
    func handleSpace(toggling: Bool) -> Bool
}

extension M1PresentationMessage {
    var localizedKey: LocalizedStringKey {
        switch self {
        case .audioCapturePermissionRequired:
            "System audio capture permission is required."
        case let .audioStoppedAfterRetirementMaintenance(reason):
            "Audio stopped after retirement maintenance: \(reason)"
        case .audioDeviceMonitoringUnavailable:
            "Audio device monitoring is unavailable; waiting for a system device event."
        case let .capturePermissionVerificationFailed(reason):
            "Audio stopped because capture permission verification failed: \(reason)"
        case let .capturePermissionCleanupFailed(reason):
            "Audio cleanup after capture permission verification failed: \(reason)"
        case let .automaticAudioRecoveryPaused(reason):
            "Automatic audio recovery paused: \(reason)"
        case .configurationDurabilityUncertain:
            "Configuration durability is uncertain"
        case .editorChangeCouldNotApply:
            "An editor change could not be applied"
        case .configurationRepairFailed:
            "Configuration repair failed"
        case .terminationCancelled:
            "Termination cancelled"
        case let .technical(reason):
            "Operation failed: \(reason)"
        }
    }

    func localizedString(locale: Locale) -> String {
        switch self {
        case .audioCapturePermissionRequired:
            String(localized: "System audio capture permission is required.", locale: locale)
        case let .audioStoppedAfterRetirementMaintenance(reason):
            String(localized: "Audio stopped after retirement maintenance: \(reason)", locale: locale)
        case .audioDeviceMonitoringUnavailable:
            String(
                localized: "Audio device monitoring is unavailable; waiting for a system device event.",
                locale: locale
            )
        case let .capturePermissionVerificationFailed(reason):
            String(localized: "Audio stopped because capture permission verification failed: \(reason)", locale: locale)
        case let .capturePermissionCleanupFailed(reason):
            String(localized: "Audio cleanup after capture permission verification failed: \(reason)", locale: locale)
        case let .automaticAudioRecoveryPaused(reason):
            String(localized: "Automatic audio recovery paused: \(reason)", locale: locale)
        case .configurationDurabilityUncertain:
            String(localized: "Configuration durability is uncertain", locale: locale)
        case .editorChangeCouldNotApply:
            String(localized: "An editor change could not be applied", locale: locale)
        case .configurationRepairFailed:
            String(localized: "Configuration repair failed", locale: locale)
        case .terminationCancelled:
            String(localized: "Termination cancelled", locale: locale)
        case let .technical(reason):
            String(localized: "Operation failed: \(reason)", locale: locale)
        }
    }
}

extension M1ApplicationLanguage {
    var titleKey: LocalizedStringKey {
        switch self {
        case .system: "Follow System"
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }
}

var m1ApplicationLocale: Locale {
    let rawValue = UserDefaults.standard.string(forKey: M1ApplicationLanguage.defaultsKey)
    return (M1ApplicationLanguage(rawValue: rawValue ?? "") ?? .system).locale
}

let m1NodeDragType = UTType(exportedAs: "com.ruimingchen.equalizerau.preamp-node-drag")

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
        requestedEffectsEnabled: M1ConfigurationSnapshot.transparentRecovery.effectsEnabled,
        appliedEffectsEnabled: nil,
        processingTransition: .idle,
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
    private var latestEditError: M1PresentationMessage?
    private var draggedNodeID: UUID?
    let pendingEditorCommitCoordinator = M1PendingEditorCommitCoordinator()
    private let pasteboard: any M1PasteboardAccess
    private let audioLifecycleMonitor: (any M1AudioLifecycleMonitoring)?
    private let wavPicker: @MainActor () -> URL?
    private let diagnosticsPresenter: @MainActor (String) -> Void
    private let textCommandRouter: any M1TextCommandRouting

    init(
        controller: M1ProductController,
        pasteboard: any M1PasteboardAccess,
        audioLifecycleMonitor: (any M1AudioLifecycleMonitoring)?,
        wavPicker: @escaping @MainActor () -> URL?,
        diagnosticsPresenter: @escaping @MainActor (String) -> Void,
        textCommandRouter: any M1TextCommandRouting
    ) {
        self.controller = controller
        self.pasteboard = pasteboard
        self.audioLifecycleMonitor = audioLifecycleMonitor
        self.wavPicker = wavPicker
        self.diagnosticsPresenter = diagnosticsPresenter
        self.textCommandRouter = textCommandRouter
    }

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        perform {
            await self.controller.bootstrap()
            try self.audioLifecycleMonitor?.start { [weak self] event in
                Task { @MainActor [weak self] in
                    await self?.handleAudioLifecycleEvent(event)
                }
            }
        }
    }

    func applicationDidBecomeActive() {
        perform {
            await self.controller.handleApplicationActivation()
        }
    }

    func handleAudioLifecycleEvent(_ event: M1AudioLifecycleEvent) async {
        await controller.handleAudioLifecycleEvent(event)
        snapshot = await controller.snapshot()
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
        let ir = M1ConvolutionIRStore.reference(sourceURL: url)
        performEdit { try await self.controller.addConvolution(before: id, ir: ir) }
    }

    func replaceConvolutionIR(id: UUID) {
        guard let url = selectWAV() else { return }
        let ir = M1ConvolutionIRStore.reference(sourceURL: url)
        performEdit { try await self.controller.setConvolutionIR(id: id, ir: ir) }
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
        if textCommandRouter.handleSpace(toggling: toggling) { return }
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
        perform(waitsForPredecessor: false) {
            try await self.controller.setProcessingEnabled(enabled)
        }
    }

    private func selectWAV() -> URL? {
        wavPicker()
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
                diagnosticsPresenter(diagnosticsText(snapshot.realtimeDiagnostics))
            } catch {
                await controller.reportCommandError(String(describing: error))
                snapshot = await controller.snapshot()
            }
        }
    }

    private func diagnosticsText(_ diagnostics: M1RealtimeDiagnostics?) -> String {
        guard let diagnostics else {
            return String(localized: "No running audio route is available.", locale: m1ApplicationLocale)
        }
        return [
            String(localized: "Captured frames: \(diagnostics.io.capturedFrames)", locale: m1ApplicationLocale),
            String(localized: "Rendered frames: \(diagnostics.io.renderedFrames)", locale: m1ApplicationLocale),
            String(localized: "Overflow blocks: \(diagnostics.io.overflowedBlocks)", locale: m1ApplicationLocale),
            String(localized: "Underrun blocks: \(diagnostics.io.underrunBlocks)", locale: m1ApplicationLocale),
            String(localized: "Dropped backlog frames: \(diagnostics.io.droppedBacklogFrames)", locale: m1ApplicationLocale),
            String(
                localized: "Invalid callbacks/process calls: \(diagnostics.io.invalidCallbacks + diagnostics.runtime.invalidProcessCalls)",
                locale: m1ApplicationLocale
            ),
            String(
                localized: "Overlapping callbacks: \(diagnostics.io.overlappingRenderCallbacks + diagnostics.runtime.overlappingCallbacks)",
                locale: m1ApplicationLocale
            ),
            String(localized: "Non-finite input samples: \(diagnostics.runtime.nonFiniteInputSamples)", locale: m1ApplicationLocale),
            String(localized: "Saturated output samples: \(diagnostics.runtime.saturatedOutputSamples)", locale: m1ApplicationLocale),
        ].joined(separator: "\n")
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
            return .stayOpen(latestEditError ?? .editorChangeCouldNotApply)
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

    private func perform(
        waitsForPredecessor: Bool = true,
        _ operation: @escaping @MainActor () async throws -> Void
    ) {
        guard !terminationPending else { return }
        commandSequence &+= 1
        let predecessor = commandTask
        let precedingEdits = editTask
        let operationTask = Task {
            if waitsForPredecessor { await predecessor?.value }
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
        if waitsForPredecessor {
            commandTask = operationTask
        } else {
            commandTask = Task {
                await predecessor?.value
                await operationTask.value
            }
        }
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
            var currentError: M1PresentationMessage?
            do {
                try await operation()
            } catch {
                let message = String(describing: error)
                currentError = .technical(message)
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
        textCommandRouter.route(selector)
    }

    private func routeTextHistory(redo: Bool) -> Bool {
        textCommandRouter.routeHistory(redo: redo)
    }

    func waitUntilIdle() async {
        await drainCommands()
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

