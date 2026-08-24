import AppKit
import Foundation
import UniformTypeIdentifiers

struct M1SystemTextCommandRouter: M1TextCommandRouting {
    func route(_ selector: Selector) -> Bool {
        guard NSApp?.keyWindow?.firstResponder is NSTextView else { return false }
        return NSApp.sendAction(selector, to: nil, from: nil)
    }

    func routeHistory(redo: Bool) -> Bool {
        guard let textView = NSApp?.keyWindow?.firstResponder as? NSTextView else { return false }
        guard let undoManager = textView.undoManager else { return true }
        if redo {
            if undoManager.canRedo { undoManager.redo() }
        } else if undoManager.canUndo {
            undoManager.undo()
        }
        return true
    }

    func handleSpace(toggling: Bool) -> Bool {
        guard let textView = NSApp?.keyWindow?.firstResponder as? NSTextView else { return false }
        if !toggling {
            textView.insertText(" ", replacementRange: textView.selectedRange())
        }
        return true
    }
}

enum M1SystemWAVPicker {
    @MainActor
    static func select() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}

enum M1SystemDiagnosticsPresenter {
    @MainActor
    static func present(_ text: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Realtime Diagnostics", locale: m1ApplicationLocale)
        alert.informativeText = text
        alert.addButton(withTitle: String(localized: "OK", locale: m1ApplicationLocale))
        alert.runModal()
    }
}

final class M1SystemPasteboard: M1PasteboardAccess, @unchecked Sendable {
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

