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
            contentRect: NSRect(x: 0, y: 0, width: AppSettings.shared.clipboardLayout.width, height: AppSettings.shared.clipboardLayout.height),
            styleMask: [.borderless],
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
        let hostingView = NSHostingView(rootView: ClipboardHistoryView(viewModel: viewModel))
        hostingView.wantsLayer = true
        // Clip the native surface too, so glass rendering cannot expose square window corners.
        hostingView.layer?.cornerRadius = ClipboardGlass.panelCornerRadius
        hostingView.layer?.masksToBounds = true
        panel.contentView = hostingView

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
            self.dismiss(reactivateTarget: false)
            self.pasteService.requestAccessibilityPermission()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshAccessibilityPermission),
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidResignActive), name: NSApplication.didResignActiveNotification, object: NSApp)
        NotificationCenter.default.addObserver(self, selector: #selector(updateLayout), name: .clipboardLayoutDidChange, object: nil)
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

    func showImportedHistory() {
        viewModel.query = ""
        viewModel.sourceFilter = ""
        viewModel.contentFilter = .all
        viewModel.groupFilter = .all
        show()
    }

    func show() {
        if !panel.isVisible {
            let frontmost = NSWorkspace.shared.frontmostApplication
            if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                targetApplication = frontmost
            }

            viewModel.prepareForPresentation(
                hasAccessibilityPermission: pasteService.hasAccessibilityPermission
            )
            positionPanel()
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.attachedSheet?.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
    }

    func dismiss(reactivateTarget: Bool) {
        viewModel.cancelPendingPaste()
        panel.orderOut(nil)
        guard reactivateTarget else { return }
        targetApplication?.activate(options: [])
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isCompletingPaste, !viewModel.isPresentingOverlay, !viewModel.isPresentingContextMenu,
              panel.attachedSheet == nil, panel.isVisible else { return }
        dismiss(reactivateTarget: false)
    }

    @objc private func applicationDidResignActive() {
        // A popover may already hold key focus, so clicking another app does not make the panel resign key again.
        guard !isCompletingPaste, panel.attachedSheet == nil else { return }
        dismiss(reactivateTarget: false)
    }

    @objc private func refreshAccessibilityPermission() {
        viewModel.hasAccessibilityPermission = pasteService.hasAccessibilityPermission
    }

    @objc private func updateLayout() {
        let layout = AppSettings.shared.clipboardLayout
        let previous = panel.frame
        panel.setContentSize(NSSize(width: layout.width, height: layout.height))
        panel.setFrameOrigin(NSPoint(x: previous.midX - panel.frame.width / 2, y: previous.maxY - panel.frame.height))
        panel.invalidateShadow()
    }

    private func paste(_ item: ClipboardItem) {
        guard panel.isVisible else { return }
        guard pasteService.writeToPasteboard(item) else {
            NSSound.beep()
            return
        }

        isCompletingPaste = true
        dismiss(reactivateTarget: true)

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
            guard let self, let window = event.window, window.isKeyWindow,
                  window === self.panel || window.sheetParent === self.panel else { return event }

            let selectsAll = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
                && event.charactersIgnoringModifiers?.lowercased() == "a"
            // The menu-bar app has no standard Edit menu to dispatch this text command.
            if selectsAll, let editor = window.firstResponder as? NSTextView {
                editor.selectAll(nil)
                return nil
            }
            guard window === self.panel, !self.viewModel.isPresentingOverlay, !self.viewModel.isPresentingContextMenu,
                  self.panel.attachedSheet == nil else { return event }

            if selectsAll {
                self.viewModel.selectAll()
                return nil
            }

            switch Int(event.keyCode) {
            case 53: // Escape
                self.dismiss(reactivateTarget: true)
                return nil
            case 36, 76: // Return / keypad Enter
                self.viewModel.pasteSelected()
                return nil
            case 125: // Down
                self.viewModel.moveSelection(by: 1, extending: event.modifierFlags.contains(.shift))
                return nil
            case 126: // Up
                self.viewModel.moveSelection(by: -1, extending: event.modifierFlags.contains(.shift))
                return nil
            default:
                break
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
