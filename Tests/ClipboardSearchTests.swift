import AppKit
import Combine

private final class SearchFileManager: FileManager, @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private var gate: (started: DispatchSemaphore, resume: DispatchSemaphore)?

    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        directory == .applicationSupportDirectory ? [root] : super.urls(for: directory, in: domainMask)
    }

    func pauseStorage() -> (started: DispatchSemaphore, resume: DispatchSemaphore) {
        let value = (started: DispatchSemaphore(value: 0), resume: DispatchSemaphore(value: 0))
        lock.lock(); gate = value; lock.unlock()
        return value
    }

    override func fileExists(atPath path: String) -> Bool {
        if URL(fileURLWithPath: path).lastPathComponent == "history.json" {
            lock.lock(); let value = gate; gate = nil; lock.unlock()
            if let value {
                value.started.signal()
                precondition(value.resume.wait(timeout: .now() + 10) == .success)
            }
        }
        return super.fileExists(atPath: path)
    }
}

@main
@MainActor
struct ClipboardSearchTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLite-search-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = SearchFileManager(root: root)
        let repository = ClipboardRepository(fileManager: manager)
        try await waitUntil { repository.isReady }
        let batch = try PerformanceFixtures.makeBatch(count: 610, root: root)
        let preview = try await repository.previewImport(batch)
        _ = try await repository.importBatch(batch, preview: preview, expand: false)
        let model = ClipboardViewModel(repository: repository)
        try await waitUntil { model.filteredItems.count == 200 && !model.isLoading }
        let originalItems = model.filteredItems
        let originalSelection = model.selectedIDs
        var scrolls = 0
        var pastes = 0
        let scrolling = model.keyboardScrollRequests.sink { _ in scrolls += 1 }
        model.onPaste = { _ in pastes += 1 }
        defer { scrolling.cancel() }

        // Pause the serial storage queue with a no-op deletion; the history itself is unchanged.
        let gate = manager.pauseStorage()
        let blocker = Task { try await repository.deleteItems([UUID()]) }
        await Task.detached { precondition(gate.started.wait(timeout: .now() + 5) == .success) }.value
        model.query = "Fixture"
        model.pasteSelected() // Also reject old results during the text debounce.
        try await waitUntil { model.isLoading }
        precondition(model.filteredItems == originalItems && model.selectedIDs == originalSelection)
        precondition(!model.showsInitialLoading)
        model.pasteSelected()
        model.paste(originalItems[0])
        model.query = "No matching fixture"
        try await Task.sleep(for: .milliseconds(150))
        model.query = "Record 2"
        try await Task.sleep(for: .milliseconds(150))
        precondition(model.filteredItems == originalItems && model.selectedIDs == originalSelection)
        gate.resume.signal()
        try await blocker.value
        let expected = try await repository.query(ClipboardQuery(text: "Record 2"))
        try await waitUntil { !model.isLoading && model.filteredItems == expected.items }
        precondition(model.selectedIDs == [expected.items[0].id] && pastes == 0 && scrolls == 0)
        print("PASS: pending and cancelled searches retain displayed rows and highlight, do not paste stale results, and apply only the latest result without scrolling")

        model.query = "Fixture"
        try await waitUntil { !model.isLoading && model.resultCount == 610 }
        let sameItems = model.filteredItems
        var changedRows = 0
        let rows = model.$filteredItems.dropFirst().sink { _ in changedRows += 1 }
        model.query = "Fixture App"
        try await Task.sleep(for: .milliseconds(200))
        try await waitUntil { !model.isLoading }
        precondition(model.filteredItems == sameItems && changedRows == 0)
        rows.cancel()
        print("PASS: refining a keyword with identical matches does not republish or replace the displayed rows")

        model.selectForClick(model.filteredItems[3])
        model.selectForClick(model.filteredItems[5], toggling: true)
        model.query = "Record"
        try await waitUntil { !model.isLoading && model.resultCount == 366 }
        precondition(model.selectedIDs == [model.filteredItems[0].id])
        model.query = "Fixture"
        model.selectAll()
        try await waitUntil { !model.isLoading && !model.isSelectingAll && model.selectedIDs.count == 610 }
        precondition(model.filteredItems.count == 200 && model.resultCount == 610)
        print("PASS: a new result resets the old multi-selection while Select All retains all matching off-page IDs")

        model.query = "No matching fixture"
        try await waitUntil { !model.isLoading && model.filteredItems.isEmpty }
        let emptyGate = manager.pauseStorage()
        let emptyBlocker = Task { try await repository.deleteItems([UUID()]) }
        await Task.detached { precondition(emptyGate.started.wait(timeout: .now() + 5) == .success) }.value
        model.query = "Still no matching fixture"
        try await waitUntil { model.isLoading }
        precondition(model.filteredItems.isEmpty && !model.showsInitialLoading)
        emptyGate.resume.signal()
        try await emptyBlocker.value
        try await waitUntil { !model.isLoading }
        precondition(model.filteredItems.isEmpty && model.selectedIDs.isEmpty && scrolls == 0)
        print("PASS: subsequent empty searches retain the empty state instead of flashing an initial-load spinner")
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        precondition(condition(), "Timed out")
    }
}
