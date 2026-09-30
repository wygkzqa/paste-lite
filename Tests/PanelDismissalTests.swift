import AppKit
import SwiftUI

private final class PanelFileManager: FileManager, @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private var deletionGate: (started: DispatchSemaphore, resume: DispatchSemaphore)?

    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        directory == .applicationSupportDirectory ? [root] : super.urls(for: directory, in: domainMask)
    }

    func pauseNextDeletion() -> (started: DispatchSemaphore, resume: DispatchSemaphore) {
        let gate = (started: DispatchSemaphore(value: 0), resume: DispatchSemaphore(value: 0))
        lock.lock()
        deletionGate = gate
        lock.unlock()
        return gate
    }

    override func fileExists(atPath path: String) -> Bool {
        if URL(fileURLWithPath: path).lastPathComponent == "history.json" {
            lock.lock()
            let gate = deletionGate
            deletionGate = nil
            lock.unlock()
            if let gate {
                gate.started.signal()
                precondition(gate.resume.wait(timeout: .now() + 10) == .success, "Storage was never resumed")
            }
        }
        return super.fileExists(atPath: path)
    }
}

private final class PanelTestPopUpButton: NSPopUpButton {
    override var acceptsFirstResponder: Bool { true }
}

@main
@MainActor
struct PanelDismissalTests {
    static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLite-panel-tests-\(UUID())")
        let pasteboard = NSPasteboard(name: .init("PasteLite-panel-tests-\(UUID())"))
        defer {
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: root)
        }
        let manager = PanelFileManager(root: root)
        let repository = ClipboardRepository(fileManager: manager)
        for _ in 0..<500 where !repository.isReady {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(repository.isReady)
        let monitor = ClipboardMonitor(repository: repository, pasteboard: pasteboard, loadSourceIcon: { _ in nil })
        let service = PasteService(repository: repository, monitor: monitor, pasteboard: pasteboard)
        let controller = ClipboardPanelController(repository: repository, pasteService: service)
        let panel = app.windows.compactMap { $0 as? ClipboardPanel }.first!
        precondition(!panel.isMovableByWindowBackground, "The production panel must dispatch background moves after controls handle their drags")
        let hosting = panel.contentView as! NSHostingView<ClipboardHistoryView>
        let model = hosting.rootView.viewModel
        // Exercise native notifications in this process without activating a window over the user's apps.
        panel.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        panel.orderFront(nil)
        precondition(panel.isVisible)
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel))
        precondition(!panel.isVisible)

        panel.orderFront(nil)
        model.isPresentingOverlay = true
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel))
        precondition(panel.isVisible, "Opening a filter popover must retain its parent panel")
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: app)
        precondition(!panel.isVisible, "Leaving the app must close the panel even if a popover already took key focus")
        model.isPresentingOverlay = false

        panel.orderFront(nil)
        model.isPresentingContextMenu = true
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: app)
        precondition(!panel.isVisible)
        model.isPresentingContextMenu = false
        print("PASS: ordinary focus loss dismisses the panel; popover focus retains it until application deactivation, including an open context menu")

        panel.orderFront(nil)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        panel.beginSheet(sheet, completionHandler: nil)
        precondition(panel.attachedSheet === sheet)
        model.isPresentingOverlay = true
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel))
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: app)
        precondition(panel.isVisible && panel.attachedSheet === sheet, "Deactivation must preserve an attached editing or preview sheet")
        panel.endSheet(sheet)
        sheet.orderOut(nil)
        model.isPresentingOverlay = false
        panel.orderOut(nil)
        print("PASS: attached editing and preview sheets survive application deactivation")

        for text in ["First synthetic entry", "Second synthetic entry"] {
            repository.record(ClipboardCapture(type: .text, textContent: text, imageData: nil, filePaths: [],
                sourceAppName: "Fixture", sourceBundleID: "example.fixture", capturedAt: Date()))
        }
        try await waitUntil { model.filteredItems.count == 2 && !model.isLoading }
        let first = model.filteredItems[0]
        let second = model.filteredItems[1]
        checkMouseSelection(model, first: first, second: second)

        model.prepareForPresentation()
        panel.orderFront(nil)
        model.select(first)
        model.copySelected()
        try await waitUntil { !panel.isVisible }
        let fullFirst = try await repository.item(id: first.id)!
        precondition(pasteboard.string(forType: .string) == fullFirst.textContent)
        precondition(model.errorMessage == nil)
        print("PASS: copying a selected record writes its full contents to the named clipboard and dismisses the panel")

        model.prepareForPresentation()
        panel.orderFront(nil)
        let missingFile = root.appendingPathComponent("missing-fixture.txt")
        let unavailableItem = ClipboardItem(id: UUID(), type: .file, textContent: nil, assetFilename: nil,
            thumbnailFilename: nil, filePaths: [missingFile.path], sourceAppName: "Fixture",
            sourceBundleID: "example.fixture", contentHash: "missing-fixture", createdAt: Date(), lastCopiedAt: Date())
        model.onCopy?(unavailableItem)
        precondition(panel.isVisible, "A failed clipboard write must keep the panel open")
        controller.dismiss(reactivateTarget: false)
        pasteboard.setString("Keep named clipboard", forType: .string)
        model.onCopy?(fullFirst)
        precondition(pasteboard.string(forType: .string) == "Keep named clipboard", "A hidden panel must reject copy requests")
        print("PASS: a failed clipboard write retains the panel; a hidden panel does not overwrite the clipboard")

        var copiedIDs: [UUID] = []
        // Observe requests without accessing the system clipboard.
        model.onCopy = { copiedIDs.append($0.id) }
        pasteboard.setString("Keep named clipboard", forType: .string)

        for dismissal in ["explicit", "key loss", "application deactivation"] {
            model.prepareForPresentation()
            panel.orderFront(nil)
            let gate = manager.pauseNextDeletion()
            // Deleting a nonexistent ID holds the storage queue without removing either fixture.
            let deletion = Task { try await repository.deleteItems([UUID()]) }
            try await waitUntil { gate.started.wait(timeout: .now()) == .success }
            model.copy(first)
            try await Task.sleep(for: .milliseconds(10))
            switch dismissal {
            case "explicit": controller.dismiss(reactivateTarget: false)
            case "key loss": controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel))
            default:
                model.isPresentingOverlay = true
                NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: app)
                model.isPresentingOverlay = false
            }
            precondition(!panel.isVisible)
            gate.resume.signal()
            try await deletion.value
            precondition(copiedIDs.isEmpty, "A copy survived \(dismissal)")
            precondition(model.errorMessage == nil && pasteboard.string(forType: .string) == "Keep named clipboard")
        }
        print("PASS: explicit dismissal, key loss and application deactivation cancel queued copy reads without changing the clipboard")

        model.prepareForPresentation()
        panel.orderFront(nil)
        let gate = manager.pauseNextDeletion()
        let deletion = Task { try await repository.deleteItems([UUID()]) }
        try await waitUntil { gate.started.wait(timeout: .now()) == .success }
        model.copy(first)
        try await Task.sleep(for: .milliseconds(10))
        controller.dismiss(reactivateTarget: false)
        model.prepareForPresentation()
        panel.orderFront(nil)
        model.copy(second)
        model.copy(first)
        gate.resume.signal()
        try await deletion.value
        try await waitUntil { !copiedIDs.isEmpty }
        precondition(copiedIDs == [second.id], "Only the new presentation's request should finish")
        model.copy(first)
        try await waitUntil { copiedIDs.count == 2 }
        precondition(copiedIDs == [second.id, first.id])
        controller.dismiss(reactivateTarget: false)
        print("PASS: reopening accepts a new copy, rejects stale/overlapping requests, and allows subsequent copies after completion")
    }

    private static func checkMouseSelection(_ model: ClipboardViewModel, first: ClipboardItem, second: ClipboardItem) {
        let view = ClipboardItemContextMenu.MenuView(frame: NSRect(x: 0, y: 0, width: 200, height: 54))
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        let popup = PanelTestPopUpButton(frame: NSRect(x: 0, y: 0, width: 100, height: 24), pullsDown: false)
        popup.addItem(withTitle: "All Types")
        view.addSubview(popup)
        var activations = 0
        view.actions = ClipboardItemContextMenu(
            onSelect: { model.selectForClick(second, toggling: $0.contains(.command), extending: $0.contains(.shift)) },
            onDoubleClick: { activations += 1 },
            onOpen: { model.selectForContextMenu(second) }, onClose: {}, onEdit: {}, onPreview: {},
            groups: [], selection: { model.selectionForContextMenu }, onSelectAll: {},
            onGroup: { _, _, _ in }, onNewGroup: { _ in }, onDelete: { _ in })
        func event(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags = [], clicks: Int = 1, point: NSPoint = NSPoint(x: 20, y: 20)) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }

        model.select(first)
        precondition(window.makeFirstResponder(popup) && window.firstResponder === popup)
        view.mouseDown(with: event(.leftMouseDown))
        precondition(window.firstResponder !== popup, "Selecting a record must release the type selector's keyboard focus")
        precondition(model.selectedIDs == [second.id] && activations == 0, "Selection must finish before mouse-up")
        view.mouseUp(with: event(.leftMouseUp))
        precondition(model.selectedIDs == [second.id] && activations == 0)

        model.select(first)
        view.mouseDown(with: event(.leftMouseDown, .command))
        precondition(model.selectedIDs == [first.id, second.id])
        view.mouseUp(with: event(.leftMouseUp, .command))
        precondition(model.selectedIDs == [first.id, second.id], "Mouse-up must not toggle the entry a second time")
        view.mouseDown(with: event(.leftMouseDown, .command))
        view.mouseUp(with: event(.leftMouseUp, .command))
        precondition(model.selectedIDs == [first.id])
        model.select(first)
        view.mouseDown(with: event(.leftMouseDown, .shift))
        precondition(model.selectedIDs == [first.id, second.id])
        view.mouseUp(with: event(.leftMouseUp, .shift))
        precondition(window.makeFirstResponder(popup) && window.firstResponder === popup)
        _ = view.menu(for: event(.rightMouseDown))
        precondition(window.firstResponder !== popup, "Opening a record menu must release the type selector's keyboard focus")
        precondition(model.selectedIDs == [first.id, second.id] && activations == 0)
        print("PASS: mouse-down immediately selects, command/shift selection applies once, and right-click preserves multiple selection")
        print("PASS: left-click and right-click release focused type selectors without changing record selection semantics")

        view.mouseDown(with: event(.leftMouseDown, clicks: 2))
        precondition(activations == 0, "Double-click must wait for release")
        view.mouseUp(with: event(.leftMouseUp, clicks: 2))
        precondition(activations == 1)
        for flags: NSEvent.ModifierFlags in [.command, .shift] {
            view.mouseDown(with: event(.leftMouseDown, flags, clicks: 2))
            view.mouseUp(with: event(.leftMouseUp, flags, clicks: 2))
        }
        view.mouseDown(with: event(.leftMouseDown, clicks: 2))
        view.mouseDragged(with: event(.leftMouseDragged))
        view.mouseUp(with: event(.leftMouseUp, clicks: 2))
        view.mouseDown(with: event(.leftMouseDown, clicks: 2))
        view.mouseUp(with: event(.leftMouseUp, clicks: 2, point: NSPoint(x: 250, y: 20)))
        precondition(activations == 1, "Modified clicks, drags and releases outside the entry must not activate copying")
        print("PASS: double-click activates once on release; modifiers, dragging and release outside cancel activation")
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out")
    }
}
