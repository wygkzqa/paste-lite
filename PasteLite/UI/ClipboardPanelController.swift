import AppKit
import SwiftUI

@MainActor
final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class ClipboardPanelController: NSObject, NSWindowDelegate {
    private let panel: ClipboardPanel
    private let viewModel: ClipboardViewModel
    private let pasteService: PasteService
    private var targetApplication: NSRunningApplication?
    private var localKeyMonitor: Any?
    private var isCompletingPaste = false

    init(repository: ClipboardRepository, pasteService: PasteService) {
        self.pasteService = pasteService
        viewModel = ClipboardViewModel(repository: repository)

        panel = ClipboardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = "Paste Lite"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ClipboardHistoryView(viewModel: viewModel))

        viewModel.onPaste = { [weak self] item in
            self?.paste(item)
        }
        viewModel.onDismiss = { [weak self] in
            self?.dismiss(reactivateTarget: true)
        }
        viewModel.onRequestAccessibilityPermission = { [weak self] in
            guard let self else { return }
            self.refreshAccessibilityPermission()
            guard !self.viewModel.hasAccessibilityPermission else { return }
            self.panel.orderOut(nil)
            self.pasteService.requestAccessibilityPermission()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshAccessibilityPermission),
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
        installLocalKeyMonitor()
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible {
            dismiss(reactivateTarget: true)
        } else {
            show()
        }
    }

    func show() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            targetApplication = frontmost
        }

        viewModel.prepareForPresentation(
            hasAccessibilityPermission: pasteService.hasAccessibilityPermission
        )
        positionPanel()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss(reactivateTarget: Bool) {
        panel.orderOut(nil)
        guard reactivateTarget else { return }
        targetApplication?.activate(options: [])
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isCompletingPaste, panel.isVisible else { return }
        panel.orderOut(nil)
    }

    @objc private func refreshAccessibilityPermission() {
        viewModel.hasAccessibilityPermission = pasteService.hasAccessibilityPermission
    }

    private func paste(_ item: ClipboardItem) {
        guard pasteService.writeToPasteboard(item) else {
            NSSound.beep()
            return
        }

        isCompletingPaste = true
        panel.orderOut(nil)
        let target = targetApplication
        target?.activate(options: [])

        guard pasteService.hasAccessibilityPermission else {
            isCompletingPaste = false
            NSSound.beep()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            self.pasteService.pasteIntoFrontmostApplication()
            self.isCompletingPaste = false
        }
    }

    private func positionPanel() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else {
            panel.center()
            return
        }
        let frame = panel.frame
        let x = visibleFrame.midX - frame.width / 2
        let y = visibleFrame.midY - frame.height / 2 + 40
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func installLocalKeyMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }

            switch Int(event.keyCode) {
            case 53: // Escape
                self.dismiss(reactivateTarget: true)
                return nil
            case 36, 76: // Return / keypad Enter
                self.viewModel.pasteSelected()
                return nil
            case 125: // Down
                self.viewModel.moveSelection(by: 1)
                return nil
            case 126: // Up
                self.viewModel.moveSelection(by: -1)
                return nil
            default:
                break
            }

            if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
               let value = Int(event.charactersIgnoringModifiers ?? ""),
               (1...9).contains(value) {
                self.viewModel.pasteItem(at: value - 1)
                return nil
            }
            return event
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
    }
}
