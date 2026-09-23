import AppKit
import ApplicationServices
import Carbon.HIToolbox

@MainActor
final class PasteService {
    private let pasteboard: NSPasteboard
    private let repository: ClipboardRepository
    private let monitor: ClipboardMonitor

    init(
        repository: ClipboardRepository,
        monitor: ClipboardMonitor,
        pasteboard: NSPasteboard = .general
    ) {
        self.repository = repository
        self.monitor = monitor
        self.pasteboard = pasteboard
    }

    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        guard NSWorkspace.shared.open(settingsURL) else {
            let alert = NSAlert()
            alert.messageText = "无法打开系统设置"
            alert.informativeText = "请前往“系统设置 → 隐私与安全性 → 辅助功能”，为 Paste Lite 开启权限。"
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
    }

    @discardableResult
    func writeToPasteboard(_ item: ClipboardItem) -> Bool {
        pasteboard.clearContents()

        let succeeded: Bool
        switch item.type {
        case .text:
            succeeded = item.textContent.map { pasteboard.setString($0, forType: .string) } ?? false

        case .url:
            if let text = item.textContent, let url = URL(string: text) {
                succeeded = pasteboard.writeObjects([url as NSURL])
            } else {
                succeeded = false
            }

        case .image:
            if let url = repository.assetURL(for: item), let image = NSImage(contentsOf: url) {
                succeeded = pasteboard.writeObjects([image])
            } else {
                succeeded = false
            }

        case .file:
            let urls = item.filePaths
                .map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            succeeded = !urls.isEmpty && pasteboard.writeObjects(urls as [NSURL])
        }

        if succeeded {
            monitor.markCurrentChangeHandled()
            repository.markUsed(item)
        }
        return succeeded
    }

    func pasteIntoFrontmostApplication() {
        guard hasAccessibilityPermission else { return }

        let source = CGEventSource(stateID: .hidSystemState)
        let keyCode = CGKeyCode(kVK_ANSI_V)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
