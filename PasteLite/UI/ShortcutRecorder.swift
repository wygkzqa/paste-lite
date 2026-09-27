import AppKit
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject var hotKeys: GlobalHotKeyManager
    let shortcut: PanelShortcut

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.target = button
        button.action = #selector(RecorderButton.beginRecording)
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.hotKeys = hotKeys
        if !hotKeys.isRecording { button.stopRecording() }
        button.title = hotKeys.isRecording ? L10n.tr("请按组合键…") : shortcut.displayName
        button.setAccessibilityLabel(L10n.tr("打开主界面快捷键"))
        button.setAccessibilityValue(button.title)
    }

    static func dismantleNSView(_ button: RecorderButton, coordinator: ()) { button.stopRecording() }

    final class RecorderButton: NSButton {
        var hotKeys: GlobalHotKeyManager?
        private var mouseMonitor: Any?
        override var acceptsFirstResponder: Bool { true }

        @objc func beginRecording() {
            guard let hotKeys, !hotKeys.isRecording, window?.makeFirstResponder(self) == true else { return }
            hotKeys.beginRecording()
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self else { return event }
                if event.window !== self.window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.stopRecording()
                }
                return event
            }
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard hotKeys?.isRecording == true, window?.firstResponder === self else {
                return super.performKeyEquivalent(with: event)
            }
            keyDown(with: event)
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard let hotKeys, hotKeys.isRecording else { super.keyDown(with: event); return }
            guard !event.isARepeat else { return }
            let shortcut = PanelShortcut(event: event)
            if event.keyCode == 53 && shortcut.modifiers == 0 {
                stopRecording()
            } else if event.keyCode == 48 && shortcut.modifierFlags.subtracting(.shift).isEmpty {
                stopRecording()
                if shortcut.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
                else { window?.selectNextKeyView(self) }
            } else if hotKeys.updateShortcut(shortcut) {
                stopRecording()
            }
        }

        override func resignFirstResponder() -> Bool {
            stopRecording()
            return super.resignFirstResponder()
        }

        func stopRecording() {
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
            hotKeys?.cancelRecording()
        }
    }
}
