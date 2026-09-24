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
        let monitor = ClipboardMonitor(repository: repository, pasteboard: pasteboard)
        let service = PasteService(repository: repository, monitor: monitor, pasteboard: pasteboard)
        let controller = ClipboardPanelController(repository: repository, pasteService: service)
        let panel = app.windows.compactMap { $0 as? ClipboardPanel }.first!
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
        precondition(panel.isVisible, "Opening a filter or permission popover must retain its parent panel")
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
        var pastedIDs: [UUID] = []
        // Observe requests without sending paste events or accessing the system clipboard.
        model.onPaste = { pastedIDs.append($0.id) }
        pasteboard.setString("Keep named clipboard", forType: .string)

        for dismissal in ["explicit", "key loss", "application deactivation"] {
            model.prepareForPresentation(hasAccessibilityPermission: false)
            panel.orderFront(nil)
            let gate = manager.pauseNextDeletion()
            // Deleting a nonexistent ID holds the storage queue without removing either fixture.
            let deletion = Task { try await repository.deleteItems([UUID()]) }
            try await waitUntil { gate.started.wait(timeout: .now()) == .success }
            model.paste(first)
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
            precondition(pastedIDs.isEmpty, "A paste survived \(dismissal)")
            precondition(model.errorMessage == nil && pasteboard.string(forType: .string) == "Keep named clipboard")
        }
        print("PASS: explicit dismissal, key loss and application deactivation cancel queued paste reads without changing the clipboard")

        model.prepareForPresentation(hasAccessibilityPermission: false)
        panel.orderFront(nil)
        let gate = manager.pauseNextDeletion()
        let deletion = Task { try await repository.deleteItems([UUID()]) }
        try await waitUntil { gate.started.wait(timeout: .now()) == .success }
        model.paste(first)
        try await Task.sleep(for: .milliseconds(10))
        controller.dismiss(reactivateTarget: false)
        model.prepareForPresentation(hasAccessibilityPermission: false)
        panel.orderFront(nil)
        model.paste(second)
        model.paste(first)
        gate.resume.signal()
        try await deletion.value
        try await waitUntil { !pastedIDs.isEmpty }
        precondition(pastedIDs == [second.id], "Only the new presentation's request should finish")
        model.paste(first)
        try await waitUntil { pastedIDs.count == 2 }
        precondition(pastedIDs == [second.id, first.id])
        controller.dismiss(reactivateTarget: false)
        print("PASS: reopening accepts a new paste, rejects stale/overlapping requests, and allows subsequent pastes after completion")
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out")
    }
}
