import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

private extension M1PresentationMessage {
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

private extension M1ApplicationLanguage {
    var titleKey: LocalizedStringKey {
        switch self {
        case .system: "Follow System"
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }
}

private var m1ApplicationLocale: Locale {
    let rawValue = UserDefaults.standard.string(forKey: M1ApplicationLanguage.defaultsKey)
    return (M1ApplicationLanguage(rawValue: rawValue ?? "") ?? .system).locale
}

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
    private var latestEditError: M1PresentationMessage?
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
                alert.messageText = String(localized: "Realtime Diagnostics", locale: m1ApplicationLocale)
                alert.informativeText = diagnosticsText(snapshot.realtimeDiagnostics)
                alert.addButton(withTitle: String(localized: "OK", locale: m1ApplicationLocale))
                alert.runModal()
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
private final class M1ApplicationBridge {
    static let shared = M1ApplicationBridge()
    weak var model: M1AppModel?

    private init() {}
}

private struct M1EditorWindowReader: NSViewRepresentable {
    let onResolve: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window { onResolve(window) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = view.window { onResolve(window) }
        }
    }
}

private enum M1StatusIndicatorState {
    case active
    case inactive
    case error
}

private final class M1StatusIndicatorView: NSView {
    var state = M1StatusIndicatorState.inactive {
        didSet { needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.75, dy: 0.75)
        let color: NSColor = switch state {
        case .active: NSColor.systemGreen
        case .inactive: NSColor.systemBlue
        case .error: NSColor.systemRed
        }
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }
}

@MainActor
private final class M1TerminationDelegate: NSObject, NSApplicationDelegate {
    weak var model: M1AppModel?
    var restoreEditorWindow: (() -> Void)?
    private weak var editorWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var statusIndicator: M1StatusIndicatorView?
    private lazy var statusIcon = makeStatusIcon()
    private var snapshotCancellable: AnyCancellable?
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        guard let model = M1ApplicationBridge.shared.model else { return }
        connect(model: model)
        installStatusItemIfNeeded()
        updateStatusItem(for: model.snapshot)
    }

    func configure(model: M1AppModel, restoreEditorWindow: @escaping () -> Void) {
        connect(model: model)
        self.restoreEditorWindow = restoreEditorWindow
        installStatusItemIfNeeded()
        statusItem?.button?.isEnabled = true
        updateStatusItem(for: model.snapshot)
    }

    private func connect(model: M1AppModel) {
        self.model = model
        guard snapshotCancellable == nil else { return }
        snapshotCancellable = model.$snapshot.sink { [weak self] snapshot in
            Task { @MainActor in self?.updateStatusItem(for: snapshot) }
        }
    }

    func applicationLanguageDidChange() {
        if let model { updateStatusItem(for: model.snapshot) }
    }

    func registerEditorWindow(_ window: NSWindow) {
        editorWindow = window
    }

    func showEditor() {
        NSApp.setActivationPolicy(.regular)
        if let editorWindow, editorWindow.isVisible {
            if editorWindow.isMiniaturized { editorWindow.deminiaturize(nil) }
            editorWindow.makeKeyAndOrderFront(nil)
        } else {
            restoreEditorWindow?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }


    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(handleStatusItemClick(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.isEnabled = restoreEditorWindow != nil
        if let button = item.button {
            let indicator = M1StatusIndicatorView()
            indicator.translatesAutoresizingMaskIntoConstraints = false
            indicator.setAccessibilityElement(false)
            button.addSubview(indicator)
            NSLayoutConstraint.activate([
                indicator.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -0.5),
                indicator.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: 0.5),
                indicator.widthAnchor.constraint(equalToConstant: 8),
                indicator.heightAnchor.constraint(equalToConstant: 8),
            ])
            statusIndicator = indicator
        }
        statusItem = item
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            presentStatusMenu()
        } else {
            showEditor()
        }
    }

    private func presentStatusMenu() {
        guard let statusItem else { return }
        statusItem.menu = makeStatusMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let locale = m1ApplicationLocale
        let snapshot = model?.snapshot
        let status = NSMenuItem(
            title: snapshot.map { statusText(for: $0, locale: locale) } ?? "EqualizerAU",
            action: nil,
            keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)
        let open = NSMenuItem(
            title: String(localized: "Open EqualizerAU", locale: locale),
            action: #selector(openFromStatusItem(_:)),
            keyEquivalent: ""
        )
        open.target = self
        menu.addItem(open)
        let processing = NSMenuItem(
            title: String(localized: "Processing", locale: locale),
            action: #selector(toggleProcessingFromStatusItem(_:)),
            keyEquivalent: ""
        )
        processing.target = self
        processing.state = snapshot?.processingEnabled == true ? .on : .off
        processing.isEnabled = snapshot?.canSetProcessing == true
        menu.addItem(processing)
        menu.addItem(.separator())
        let language = NSMenuItem(title: String(localized: "Language", locale: locale), action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        let selectedLanguage = M1ApplicationLanguage(
            rawValue: UserDefaults.standard.string(forKey: M1ApplicationLanguage.defaultsKey) ?? ""
        ) ?? .system
        for option in M1ApplicationLanguage.allCases {
            let item = NSMenuItem(
                title: languageTitle(option, locale: locale),
                action: #selector(selectLanguageFromStatusItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == selectedLanguage ? .on : .off
            languageMenu.addItem(item)
        }
        language.submenu = languageMenu
        menu.addItem(language)
        let quit = NSMenuItem(
            title: String(localized: "Quit EqualizerAU", locale: locale),
            action: #selector(quitFromStatusItem(_:)),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func languageTitle(_ language: M1ApplicationLanguage, locale: Locale) -> String {
        switch language {
        case .system: String(localized: "Follow System", locale: locale)
        case .english: String(localized: "English", locale: locale)
        case .simplifiedChinese: String(localized: "简体中文", locale: locale)
        }
    }

    @objc private func openFromStatusItem(_ sender: Any?) { showEditor() }

    @objc private func toggleProcessingFromStatusItem(_ sender: Any?) {
        guard let model else { return }
        model.setProcessing(!model.snapshot.processingEnabled)
    }

    @objc private func selectLanguageFromStatusItem(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              M1ApplicationLanguage(rawValue: rawValue) != nil else { return }
        UserDefaults.standard.set(rawValue, forKey: M1ApplicationLanguage.defaultsKey)
        applicationLanguageDidChange()
    }

    @objc private func quitFromStatusItem(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func updateStatusItem(for snapshot: M1ProductSnapshot) {
        let hasError = snapshot.visibleError != nil || snapshot.audio == .cleanupRequired
            || snapshot.audioRecovery == .permissionRequired
        statusItem?.button?.image = statusIcon
        statusIndicator?.state = hasError ? .error : snapshot.processingEnabled ? .active : .inactive
        statusItem?.button?.toolTip = statusText(for: snapshot, locale: m1ApplicationLocale)
    }

    private func makeStatusIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            for (x, handleY) in zip([3.5, 8.5, 13.5], [11.5, 6.0, 9.0]) {
                let track = NSBezierPath()
                track.move(to: NSPoint(x: x, y: 2))
                track.line(to: NSPoint(x: x, y: 16))
                track.lineWidth = 1.3
                track.lineCapStyle = .round
                track.stroke()
                NSBezierPath(
                    roundedRect: NSRect(x: x - 2, y: handleY - 1.4, width: 4, height: 2.8),
                    xRadius: 1.1,
                    yRadius: 1.1
                ).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "EqualizerAU"
        return image
    }

    private func statusText(for snapshot: M1ProductSnapshot, locale: Locale) -> String {
        if let error = snapshot.visibleError { return error.localizedString(locale: locale) }
        switch snapshot.audioRecovery {
        case .inactive:
            break
        case .suspendedForSleep:
            return String(localized: "Audio suspended while the Mac sleeps", locale: locale)
        case let .recovering(_, attempt, maximumAttempts):
            return String(
                localized: "Recovering audio route (\(attempt)/\(maximumAttempts))…",
                locale: locale
            )
        case .waitingForRetry:
            return String(localized: "Automatic recovery paused; start Processing to retry", locale: locale)
        case .permissionRequired:
            return String(localized: "System audio capture permission is required", locale: locale)
        }
        switch snapshot.persistence {
        case .clean:
            if snapshot.audio == .running {
                let key: String.LocalizationValue = snapshot.appliedEffectsEnabled == true
                    ? "Processing active"
                    : "Processing bypassed"
                return String(localized: key, locale: locale)
            }
            return String(localized: "Ready", locale: locale)
        case .modified:
            return String(localized: "Unsaved changes", locale: locale)
        case let .saving(generation):
            return String(localized: "Saving generation \(generation)…", locale: locale)
        case let .uncertain(generation):
            return String(localized: "Generation \(generation) durability is uncertain", locale: locale)
        case .recovery:
            return String(localized: "Configuration repair required", locale: locale)
        case .waitingForOutput:
            return String(localized: "Saved; waiting for an output device", locale: locale)
        case .savedPendingStart:
            return String(localized: "Saved; applies on next engine start", locale: locale)
        case let .pendingApplication(generation):
            return String(localized: "Applying generation \(generation)…", locale: locale)
        case let .failed(reason):
            return String(localized: "Operation failed: \(reason)", locale: locale)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showEditor()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        (model ?? M1ApplicationBridge.shared.model)?.applicationDidBecomeActive()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = model ?? M1ApplicationBridge.shared.model else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task {
            var decision = await model.requestTermination()
            while case let .prompt(prompt) = decision {
                guard let action = self.present(prompt) else {
                    _ = await model.resolveTermination(.cancel)
                    self.terminationPending = false
                    self.showEditor()
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
                self.showEditor()
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    private func present(_ prompt: M1TerminationPrompt) -> M1TerminationAction? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let locale = m1ApplicationLocale
        switch prompt {
        case .unsavedNodes:
            alert.messageText = String(localized: "Save changes before quitting?", locale: locale)
            alert.informativeText = String(localized: "Your Preamp edits have not been saved.", locale: locale)
            alert.addButton(withTitle: String(localized: "Save and Exit", locale: locale))
            alert.addButton(withTitle: String(localized: "Discard", locale: locale))
            alert.addButton(withTitle: String(localized: "Cancel", locale: locale))
            return action(for: alert.runModal(), primary: .saveAndExit, secondary: .discardAndExit)
        case .unsavedEffects:
            alert.messageText = String(localized: "Effects state is not saved", locale: locale)
            alert.informativeText = String(
                localized: "Retry saving, or exit and restore the on-disk state next time.",
                locale: locale
            )
            alert.addButton(withTitle: String(localized: "Retry", locale: locale))
            alert.addButton(withTitle: String(localized: "Exit", locale: locale))
            alert.addButton(withTitle: String(localized: "Cancel", locale: locale))
            return action(for: alert.runModal(), primary: .retry, secondary: .exit)
        case .unsavedNodesAndEffects:
            alert.messageText = String(localized: "Save all changes before quitting?", locale: locale)
            alert.informativeText = String(
                localized: "Preamp edits and the Effects state have not been saved.",
                locale: locale
            )
            alert.addButton(withTitle: String(localized: "Save and Exit", locale: locale))
            alert.addButton(withTitle: String(localized: "Discard and Exit", locale: locale))
            alert.addButton(withTitle: String(localized: "Cancel", locale: locale))
            return action(for: alert.runModal(), primary: .saveAndExit, secondary: .discardAndExit)
        case let .uncertainPersistence(generation):
            alert.messageText = String(localized: "Configuration durability is uncertain", locale: locale)
            alert.informativeText = String(
                localized: "Retry the final sync for generation \(generation), or exit without claiming which complete file is on disk.",
                locale: locale
            )
            alert.addButton(withTitle: String(localized: "Retry", locale: locale))
            alert.addButton(withTitle: String(localized: "Exit", locale: locale))
            alert.addButton(withTitle: String(localized: "Cancel", locale: locale))
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

private struct M1ApplicationMenuPruningCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About EqualizerAU") { NSApp.orderFrontStandardAboutPanel(nil) }
        }
        CommandGroup(replacing: .appSettings) {}
        CommandGroup(replacing: .systemServices) {}
        CommandGroup(replacing: .appVisibility) {
            Button("Hide EqualizerAU") { NSApp.hide(nil) }
                .keyboardShortcut("h")
            Button("Hide Others") { NSApp.hideOtherApplications(nil) }
                .keyboardShortcut("h", modifiers: [.command, .option])
            Button("Show All") { NSApp.unhideAllApplications(nil) }
        }
        CommandGroup(replacing: .appTermination) {
            Button("Quit EqualizerAU") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

private struct M1WindowMenuPruningCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .windowSize) {
            Button("Minimize") { NSApp.keyWindow?.miniaturize(nil) }
                .keyboardShortcut("m")
            Button("Zoom") { NSApp.keyWindow?.performZoom(nil) }
        }
    }
}

@main
struct EqualizerAUM1App: App {
    @NSApplicationDelegateAdaptor(M1TerminationDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model: M1AppModel
    @AppStorage(M1ApplicationLanguage.defaultsKey) private var applicationLanguageRawValue =
        M1ApplicationLanguage.system.rawValue
    @FocusedValue(\.m1GraphicEQSelectAllAction) private var graphicEQSelectAllAction

    private var applicationLanguage: M1ApplicationLanguage {
        M1ApplicationLanguage(rawValue: applicationLanguageRawValue) ?? .system
    }

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
        let appModel = M1AppModel(
            controller: controller,
            audioLifecycleMonitor: M1SystemAudioLifecycleMonitor()
        )
        _model = StateObject(wrappedValue: appModel)
        M1ApplicationBridge.shared.model = appModel
        appModel.bootstrap()
    }

    private func canPerformTextAction(_ action: Selector) -> Bool? {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return nil }
        let item = NSMenuItem()
        item.action = action
        return textView.validateUserInterfaceItem(item)
    }

    private func canPerformTextUndo(isRedo: Bool) -> Bool? {
        guard let undoManager = (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager else {
            return nil
        }
        return isRedo ? undoManager.canRedo : undoManager.canUndo
    }

    private func performTextAction(_ action: Selector) -> Bool {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else {
            return false
        }
        _ = textView.tryToPerform(action, with: nil)
        return true
    }

    private func performTextUndo(isRedo: Bool) -> Bool {
        guard let undoManager = (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager else {
            return false
        }
        if isRedo {
            if undoManager.canRedo { undoManager.redo() }
        } else if undoManager.canUndo {
            undoManager.undo()
        }
        return true
    }

    var body: some Scene {
        let _ = appDelegate.configure(model: model) { openWindow(id: "editor") }
        Window("EqualizerAU", id: "editor") {
            M1EditorView(model: model)
                .background {
                    M1EditorWindowReader { appDelegate.registerEditorWindow($0) }
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 760, height: 520)
        .environment(\.locale, applicationLanguage.locale)
        .commandsRemoved()
        .commands {
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.save() }
                    .keyboardShortcut("s")
                    .disabled(!model.snapshot.canSave)
                Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w")
            }
            M1ApplicationMenuPruningCommands()
            M1WindowMenuPruningCommands()
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    if !performTextUndo(isRedo: false) { model.undo() }
                }
                    .keyboardShortcut("z")
                    .disabled(!(canPerformTextUndo(isRedo: false) ?? model.snapshot.canEdit))
                Button("Redo") {
                    if !performTextUndo(isRedo: true) { model.redo() }
                }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!(canPerformTextUndo(isRedo: true) ?? model.snapshot.canEdit))
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") {
                    if !performTextAction(#selector(NSText.cut(_:))) { model.cut() }
                }
                    .keyboardShortcut("x")
                    .disabled(
                        !(canPerformTextAction(#selector(NSText.cut(_:))) ?? model.snapshot.canEdit)
                    )
                Button("Copy") {
                    if !performTextAction(#selector(NSText.copy(_:))) { model.copy() }
                }
                    .keyboardShortcut("c")
                    .disabled(
                        !(canPerformTextAction(#selector(NSText.copy(_:))) ?? model.snapshot.canEdit)
                    )
                Button("Paste") {
                    if !performTextAction(#selector(NSText.paste(_:))) { model.paste() }
                }
                    .keyboardShortcut("v")
                    .disabled(
                        !(canPerformTextAction(#selector(NSText.paste(_:))) ?? model.snapshot.canEdit)
                    )
                Button("Select All") {
                    if performTextAction(#selector(NSText.selectAll(_:))) { return }
                    if let graphicEQSelectAllAction { graphicEQSelectAllAction() }
                    else { model.selectAll() }
                }
                    .keyboardShortcut("a")
                    .disabled(
                        !(canPerformTextAction(#selector(NSText.selectAll(_:))) ?? model.snapshot.canEdit)
                    )
            }
            CommandGroup(after: .pasteboard) {
                Button("Delete") {
                    if !performTextAction(#selector(NSText.deleteBackward(_:))) {
                        model.deleteSelection()
                    }
                }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(
                        !(canPerformTextAction(#selector(NSText.deleteBackward(_:)))
                            ?? model.snapshot.canEdit)
                    )
                Divider()
                Menu("Processor Selection") {
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
            CommandGroup(after: .appInfo) {
                Menu("Language") {
                    ForEach(M1ApplicationLanguage.allCases, id: \.self) { language in
                        Button {
                            applicationLanguageRawValue = language.rawValue
                            appDelegate.applicationLanguageDidChange()
                        } label: {
                            HStack {
                                Text(language.titleKey)
                                if language == applicationLanguage { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct M1EditorView: View {
    @Environment(\.locale) private var locale
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
                diagnosticLine(
                    label: String(localized: "Active G\(generation)", locale: locale),
                    diagnostics: diagnostics
                )
            }
            if let diagnostics = model.snapshot.expectedDiagnostics,
               let generation = model.snapshot.expectedConfigurationGeneration {
                diagnosticLine(
                    label: String(localized: "Expected G\(generation)", locale: locale),
                    diagnostics: diagnostics
                )
            }
        }
        .font(.caption)
        .padding(10)
    }

    private var statusIcon: String {
        model.snapshot.visibleError == nil ? "checkmark.circle" : "exclamationmark.triangle"
    }

    private var statusText: LocalizedStringKey {
        if let error = model.snapshot.visibleError { return error.localizedKey }
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
        case let .failed(reason): return "Operation failed: \(reason)"
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
            details.append(String(
                localized: "Unresolved: \(unresolved.joined(separator: ", "))",
                locale: locale
            ))
        }
        if !diagnostics.clippingRiskChannels.isEmpty {
            details.append(String(
                localized: "Clipping risk: \(diagnostics.clippingRiskChannels.map(\.rawValue).joined(separator: ", "))",
                locale: locale
            ))
        }
        if !diagnostics.gainBoundaries.isEmpty {
            let channels = diagnostics.gainBoundaries.map { $0.channel.rawValue }
            details.append(String(
                localized: "Gain boundary: \(channels.joined(separator: ", "))",
                locale: locale
            ))
        }
        if !diagnostics.graphicEQResolution.isEmpty {
            let errors = diagnostics.graphicEQResolution.map {
                String(
                    localized: "\(formatError($0.maximumErrorDB)) max / \(formatError($0.percentile99ErrorDB)) p99",
                    locale: locale
                )
            }
            details.append(String(
                localized: "Graphic EQ FIR resolution: \(errors.joined(separator: ", "))",
                locale: locale
            ))
        }
        if !diagnostics.convolutionBypasses.isEmpty {
            details.append(String(
                localized: "Convolution bypassed: \(diagnostics.convolutionBypasses.count)",
                locale: locale
            ))
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
                    .lineLimit(2)
                    .help(nodeSubtitle(node))
            }
            .frame(minWidth: 104, idealWidth: 120, alignment: .leading)
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
        .help(nodeToggleLabel(node))
        .accessibilityLabel(nodeToggleLabel(node))
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

    private func nodeToggleLabel(_ node: M1ProcessingNode) -> String {
        let title = nodeTitle(node.kind)
        if node.isEnabled {
            return String(localized: "Disable \(title)", locale: locale)
        }
        return String(localized: "Enable \(title)", locale: locale)
    }

    private func nodeSubtitle(_ node: M1ProcessingNode) -> String {
        switch node.kind {
        case .channels:
            return scopeDiagnosticSummary(node.id)
                ?? String(localized: "Scope for following processors", locale: locale)
        case .preamp, .graphicEQ, .convolution:
            let channels = channelSummary(effectiveSelections[node.id] ?? .all)
            return String(localized: "\(channels) channels", locale: locale)
        }
    }

    private func scopeDiagnosticSummary(_ nodeID: UUID) -> String? {
        let active = model.snapshot.activeDiagnostics?.unresolvedChannels
            .first { $0.nodeID == nodeID }?.identifiers.map(\.rawValue)
        let expected = model.snapshot.expectedDiagnostics?.unresolvedChannels
            .first { $0.nodeID == nodeID }?.identifiers.map(\.rawValue)
        var parts: [String] = []
        if let active, !active.isEmpty {
            parts.append(String(
                localized: "Active unresolved: \(active.joined(separator: ", "))",
                locale: locale
            ))
        }
        if let expected, !expected.isEmpty {
            parts.append(String(
                localized: "Expected unresolved: \(expected.joined(separator: ", "))",
                locale: locale
            ))
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
            parts.append(String(
                localized: "Active FIR error: \(formatError(active.maximumErrorDB)) max, \(formatError(active.percentile99ErrorDB)) p99",
                locale: locale
            ))
        }
        if let expected {
            parts.append(String(
                localized: "Expected FIR error: \(formatError(expected.maximumErrorDB)) max, \(formatError(expected.percentile99ErrorDB)) p99",
                locale: locale
            ))
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
                    .frame(minWidth: 760, minHeight: 520)
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
        let source = convolutionSourceDiagnostic(nodeID: node.id, reference: ir)
        let bypass = convolutionBypassDiagnostic(nodeID: node.id, reference: ir)
        return HStack(spacing: 8) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(ir.sourcePath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(ir.sourcePath)
                if let bypass {
                    Text("Bypassed · \(convolutionBypassText(bypass.reason))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let source {
                    let duration = Double(source.sourceFrameCount) / source.sourceSampleRate
                    Text("\(Int(source.sourceSampleRate)) Hz · \(source.sourceChannelCount) ch · \(duration.formatted(.number.precision(.fractionLength(3)))) s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Not loaded · Save or Start to apply")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

    private func convolutionSourceDiagnostic(
        nodeID: UUID,
        reference: M1ConvolutionIRReference
    ) -> M1ConvolutionSourceDiagnostic? {
        let diagnostics = model.snapshot.expectedDiagnostics ?? model.snapshot.activeDiagnostics
        return diagnostics?.convolutionSources.first {
            $0.nodeID == nodeID && $0.source == reference
        }
    }

    private func convolutionBypassDiagnostic(
        nodeID: UUID,
        reference: M1ConvolutionIRReference
    ) -> M1ConvolutionBypassDiagnostic? {
        let diagnostics = model.snapshot.expectedDiagnostics ?? model.snapshot.activeDiagnostics
        return diagnostics?.convolutionBypasses.first {
            $0.nodeID == nodeID && $0.source == reference
        }
    }

    private func convolutionBypassText(_ reason: M1ConvolutionBypassReason) -> String {
        switch reason {
        case .resource(.missingResource):
            return String(localized: "source unavailable", locale: locale)
        case .resource(.resourceIO):
            return String(localized: "source unreadable", locale: locale)
        case .resource(.fileTooLarge):
            return String(localized: "file exceeds 32 MiB", locale: locale)
        case .resource(.invalidWAV):
            return String(localized: "invalid WAV", locale: locale)
        case .resource(.unsupportedEncoding):
            return String(localized: "unsupported WAV encoding", locale: locale)
        case .resource(.invalidMetadata):
            return String(localized: "invalid WAV metadata", locale: locale)
        case .resource(.emptyAudio):
            return String(localized: "empty WAV", locale: locale)
        case .resource(.durationExceeded):
            return String(localized: "IR exceeds 2 seconds", locale: locale)
        case .resource(.invalidSample):
            return String(localized: "invalid audio sample", locale: locale)
        case .resource:
            return String(localized: "source invalid", locale: locale)
        case let .channelCountMismatch(expected, actual):
            return String(localized: "expected \(expected) ch, found \(actual)", locale: locale)
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
        case .all: return String(localized: "All", locale: locale)
        case let .identifiers(values): return values.map(channelDisplayName).joined(separator: ", ")
        }
    }

    private func channelDisplayName(_ identifier: M1ChannelIdentifier) -> String {
        guard let channel = Int(identifier.rawValue), channel > 0 else { return identifier.rawValue }
        return String(localized: "Channel \(channel)", locale: locale)
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
        case .channels: return String(localized: "Channels", locale: locale)
        case .preamp: return String(localized: "Preamp", locale: locale)
        case .graphicEQ: return String(localized: "Graphic EQ", locale: locale)
        case .convolution: return String(localized: "Convolution", locale: locale)
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
    @State private var validationMessage: LocalizedStringKey?
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
                    .frame(minWidth: 340, idealWidth: 380, maxWidth: 440)
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
            Text(
                "FIR resolution: \(formatError(preview.maximumErrorDB)) max, \(formatError(preview.percentile99ErrorDB)) p99"
            )
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
        _ help: LocalizedStringKey,
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
        _ title: LocalizedStringKey,
        _ help: LocalizedStringKey,
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
