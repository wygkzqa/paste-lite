import AppKit
import SwiftUI

@MainActor
private final class GroupTestPanel: ClipboardPanel {
    var windowDragCount = 0
    override func performDrag(with event: NSEvent) { windowDragCount += 1 }
}

@main
@MainActor
struct ClipboardGroupDragTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let previousApplication = NSWorkspace.shared.frontmostApplication
        Task { @MainActor in
            do {
                try await runTests()
                previousApplication?.activate(options: [])
                NSApp.terminate(nil)
            } catch {
                FileHandle.standardError.write(Data("Group drag tests failed: \(error)\n".utf8))
                previousApplication?.activate(options: [])
                exit(1)
            }
        }
        NSApp.run()
    }

    private static func runTests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLite-group-drag-tests-\(UUID())")
        let previousLayout = AppSettings.shared.clipboardLayout
        defer {
            AppSettings.shared.clipboardLayout = previousLayout
            try? FileManager.default.removeItem(at: root)
        }

        for layout in ClipboardLayout.allCases {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                AppSettings.shared.clipboardLayout = layout
                let directory = root.appendingPathComponent("\(layout.rawValue)-\(appearance.rawValue)")
                let manager = PerformanceFileManager(root: directory)
                let repository = ClipboardRepository(fileManager: manager)
                try await waitUntil { repository.isReady }
                var groups: [ClipboardGroup] = []
                for name in ["One", "Two", "Three", "Four"] {
                    groups.append(try await repository.saveGroup(name: name))
                }
                let model = ClipboardViewModel(repository: repository)
                let host = NSHostingView(rootView: ClipboardHistoryView(viewModel: model))
                let window = GroupTestPanel(contentRect: NSRect(x: -10_000, y: -10_000, width: layout.width, height: layout.height),
                                            styleMask: [.borderless], backing: .buffered, defer: false)
                precondition(!window.isMovableByWindowBackground, "System background dragging must not compete with group dragging")
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                // AppKit dispatch requires an active key window. Keep it offscreen
                // and restore the previous application after the suite finishes.
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                defer { window.orderOut(nil) }
                try await waitUntil { NSApp.isActive && window.isKeyWindow && tabs(in: host).count == groups.count }
                host.layoutSubtreeIfNeeded()
                let tab: (Int) -> ClipboardGroupInteraction.MenuView = { index in
                    tabs(in: host).first { $0.interaction?.actions.group.id == groups[index].id }!
                }
                let frame: (Int) -> NSRect = { index in tab(index).convert(tab(index).bounds, to: nil) }
                let row = tab(0).enclosingScrollView!
                let rowFrame = row.convert(row.bounds, to: nil)

                // Previewing and then losing focus must not persist a reorder.
                let previewStart = NSPoint(x: frame(0).midX, y: frame(0).midY)
                let previewEnd = NSPoint(x: frame(1).midX, y: frame(1).midY)
                try await send(event(.leftMouseDown, at: previewStart, in: window))
                try await send(event(.leftMouseDragged, at: previewEnd, in: window))
                precondition(repository.groups.map(\.name) == ["One", "Two", "Three", "Four"], "A preview must not save order")
                NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
                try await Task.sleep(for: .milliseconds(250))
                try await send(event(.leftMouseUp, at: previewEnd, in: window))
                precondition(repository.groups.map(\.name) == ["One", "Two", "Three", "Four"], "Focus loss must cancel the preview")

                // Unhandled empty space still starts native window movement.
                let background = NSPoint(x: layout.width / 2, y: layout.height / 2)
                try await send(event(.leftMouseDown, at: background, in: window))
                try await send(event(.leftMouseUp, at: background, in: window))
                precondition(window.windowDragCount == 1, "Empty space must keep moving the panel")
                window.windowDragCount = 0
                let originalWindowFrame = window.frame

                // Entering the next tab must move right even when released in its leading half.
                try await drag(tab(0), in: window, to: NSPoint(x: frame(1).minX + 2, y: frame(1).midY))
                try await expect(repository, names: ["Two", "One", "Three", "Four"])
                host.layoutSubtreeIfNeeded()
                // Moving left similarly accepts the trailing half of the preceding tab.
                try await drag(tab(3), in: window, to: NSPoint(x: frame(2).maxX - 2, y: frame(2).midY))
                try await expect(repository, names: ["Two", "One", "Four", "Three"])
                host.layoutSubtreeIfNeeded()
                try await drag(tab(2), in: window, to: NSPoint(x: (frame(1).maxX + frame(0).minX) / 2, y: frame(0).midY))
                try await expect(repository, names: ["Two", "Three", "One", "Four"])
                host.layoutSubtreeIfNeeded()
                try await drag(tab(1), in: window, to: NSPoint(x: rowFrame.maxX - 8, y: rowFrame.midY))
                try await expect(repository, names: ["Three", "One", "Four", "Two"])
                host.layoutSubtreeIfNeeded()
                try await drag(tab(1), in: window, to: NSPoint(x: rowFrame.minX + 5, y: rowFrame.midY))
                try await expect(repository, names: ["Two", "Three", "One", "Four"])
                host.layoutSubtreeIfNeeded()
                precondition(model.groupFilter == .all, "Dragging must not select a different group")

                let end = NSPoint(x: frame(3).midX, y: frame(3).midY)
                try await drag(tab(0), in: window, to: end, releaseAt: NSPoint(x: end.x, y: rowFrame.minY - 15))
                try await Task.sleep(for: .milliseconds(50))
                precondition(repository.groups.map(\.name) == ["Two", "Three", "One", "Four"])
                let source = tab(0)
                let point = source.convert(NSPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
                try await send(event(.leftMouseDown, at: point, in: window))
                try await send(event(.leftMouseUp, at: point, in: window))
                precondition(model.groupFilter == .group(groups[0].id), "A normal click must still select")
                let all = NSPoint(x: rowFrame.minX + 20, y: rowFrame.midY)
                try await send(event(.leftMouseDown, at: all, in: window))
                try await send(event(.leftMouseUp, at: all, in: window))
                precondition(model.groupFilter == .all, "The SwiftUI All button must remain clickable")
                try await send(event(.leftMouseDown, at: point, in: window))
                try await send(event(.leftMouseUp, at: point, in: window))
                precondition(model.groupFilter == .group(groups[0].id))

                // Hold at either edge without more mouse events or manual scrolling.
                var expected = ["Two", "Three", "Four"]
                for index in 0..<10 {
                    let name = "Overflow \(index)"
                    _ = try await repository.saveGroup(name: name)
                    expected.append(name)
                }
                expected.append("One")
                try await waitUntil { tabs(in: host).count == 14 }
                host.layoutSubtreeIfNeeded()
                row.contentView.scroll(to: .zero)
                row.reflectScrolledClipView(row.contentView)
                let start = source.convert(NSPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
                try await send(event(.leftMouseDown, at: start, in: window))
                let edge = NSPoint(x: rowFrame.maxX - 8, y: rowFrame.midY)
                try await send(event(.leftMouseDragged, at: edge, in: window))
                let offset = row.documentView!.bounds.width - row.contentView.bounds.width
                precondition(offset > 0, "The overflow fixture must require scrolling")
                try await waitUntil { row.contentView.bounds.minX > 40 }
                let outside = NSPoint(x: edge.x, y: rowFrame.minY - 15)
                try await send(event(.leftMouseDragged, at: outside, in: window))
                let pausedOffset = row.contentView.bounds.minX
                try await Task.sleep(for: .milliseconds(200))
                precondition(row.contentView.bounds.minX == pausedOffset, "Leaving the row must stop scrolling")
                try await send(event(.leftMouseDragged, at: edge, in: window))
                try await waitUntil { row.contentView.bounds.minX >= offset - 1 }
                precondition(repository.groups.map(\.name) == ["Two", "Three", "One", "Four"] + (0..<10).map { "Overflow \($0)" },
                             "Edge scrolling must not save the preview")
                try await send(event(.leftMouseUp, at: edge, in: window))
                try await expect(repository, names: expected)
                precondition(model.groupFilter == .group(groups[0].id))

                host.layoutSubtreeIfNeeded()
                let lastTab = tab(0)
                let lastPoint = lastTab.convert(NSPoint(x: lastTab.bounds.midX, y: lastTab.bounds.midY), to: nil)
                let leftEdge = NSPoint(x: rowFrame.minX + 8, y: rowFrame.midY)
                try await send(event(.leftMouseDown, at: lastPoint, in: window))
                try await send(event(.leftMouseDragged, at: leftEdge, in: window))
                try await waitUntil { row.contentView.bounds.minX < offset - 40 }
                let middle = NSPoint(x: rowFrame.midX, y: rowFrame.midY)
                try await send(event(.leftMouseDragged, at: middle, in: window))
                let middleOffset = row.contentView.bounds.minX
                try await Task.sleep(for: .milliseconds(200))
                precondition(row.contentView.bounds.minX == middleOffset, "Moving away from the edge must stop scrolling")
                try await send(event(.leftMouseDragged, at: leftEdge, in: window))
                try await waitUntil { row.contentView.bounds.minX <= 1 }
                try await send(event(.leftMouseUp, at: leftEdge, in: window))
                expected.removeLast()
                expected.insert("One", at: 0)
                try await expect(repository, names: expected)

                // Losing focus during an unfinished edge scroll must cancel its timer and reorder.
                host.layoutSubtreeIfNeeded()
                let firstTab = tab(0)
                let firstPoint = firstTab.convert(NSPoint(x: firstTab.bounds.midX, y: firstTab.bounds.midY), to: nil)
                try await send(event(.leftMouseDown, at: firstPoint, in: window))
                try await send(event(.leftMouseDragged, at: edge, in: window))
                try await waitUntil { row.contentView.bounds.minX > 40 }
                NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
                try await Task.sleep(for: .milliseconds(50))
                let cancelledOffset = row.contentView.bounds.minX
                try await Task.sleep(for: .milliseconds(200))
                precondition(row.contentView.bounds.minX == cancelledOffset, "Focus loss must stop edge scrolling")
                try await send(event(.leftMouseUp, at: edge, in: window))
                try await expect(repository, names: expected)

                precondition(window.windowDragCount == 0, "Group clicks and drags must never start window movement")
                precondition(window.frame == originalWindowFrame, "Reordering must keep the panel in place")
                window.orderOut(nil)
                await repository.prepareForTermination()
                let reopened = ClipboardRepository(fileManager: manager)
                try await expect(reopened, names: expected)
                await reopened.prepareForTermination()
                print("PASS: \(layout.rawValue)/\(appearance.rawValue): edge holds scroll in both directions without more mouse events; leaving the edge or row and focus loss stop scrolling; previews do not save order; dragging keeps the panel still; clicks select; order survives reopen")
            }
        }
    }

    private static func tabs(in view: NSView) -> [ClipboardGroupInteraction.MenuView] {
        if let tab = view as? ClipboardGroupInteraction.MenuView { return [tab] }
        return view.subviews.flatMap { tabs(in: $0) }
    }

    private static var eventNumber = 0

    private static func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        eventNumber += 1
        return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                          windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    private static func drag(_ source: NSView, in window: NSWindow, to destination: NSPoint, releaseAt: NSPoint? = nil) async throws {
        let point = source.convert(NSPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
        let host = window.contentView!
        let hitPoint = host.superview?.convert(point, from: nil) ?? point
        precondition(host.hitTest(hitPoint) === source, "The native overlay must receive tab mouse events")
        precondition(!source.mouseDownCanMoveWindow, "Dragging a tab must not move the panel")
        try await send(event(.leftMouseDown, at: point, in: window))
        for step in 1...4 {
            let intermediate = NSPoint(x: point.x + (destination.x - point.x) * CGFloat(step) / 4,
                                       y: point.y + (destination.y - point.y) * CGFloat(step) / 4)
            try await send(event(.leftMouseDragged, at: intermediate, in: window))
        }
        try await send(event(.leftMouseUp, at: releaseAt ?? destination, in: window))
    }

    private static func send(_ event: NSEvent) async throws {
        // Use the application event queue, allowing SwiftUI updates between moves.
        NSApp.postEvent(event, atStart: false)
        try await Task.sleep(for: .milliseconds(50))
    }

    private static func expect(_ repository: ClipboardRepository, names: [String]) async throws {
        for _ in 0..<100 {
            if repository.groups.map(\.name) == names {
                // Finish the 0.18-second reorder animation before targeting the next tab.
                try await Task.sleep(for: .milliseconds(250))
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Expected \(names), got \(repository.groups.map(\.name))")
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out waiting for the expected group order or rendered tabs")
    }
}
