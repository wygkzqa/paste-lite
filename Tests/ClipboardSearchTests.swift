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
        var copies = 0
        let scrolling = model.keyboardScrollRequests.sink { _ in scrolls += 1 }
        model.onCopy = { _ in copies += 1 }
        defer { scrolling.cancel() }

        // Pause the serial storage queue with a no-op deletion; the history itself is unchanged.
        let gate = manager.pauseStorage()
        let blocker = Task { try await repository.deleteItems([UUID()]) }
        await Task.detached { precondition(gate.started.wait(timeout: .now() + 5) == .success) }.value
        model.query = "Fixture"
        model.copySelected() // Also reject old results during the text debounce.
        try await waitUntil { model.isLoading }
        precondition(model.filteredItems == originalItems && model.selectedIDs == originalSelection)
        precondition(!model.showsInitialLoading)
        model.copySelected()
        model.copy(originalItems[0])
        model.query = "No matching fixture"
        try await Task.sleep(for: .milliseconds(150))
        model.query = "Record 2"
        try await Task.sleep(for: .milliseconds(150))
        precondition(model.filteredItems == originalItems && model.selectedIDs == originalSelection)
        gate.resume.signal()
        try await blocker.value
        let expected = try await repository.query(ClipboardQuery(text: "Record 2"))
        try await waitUntil { !model.isLoading && model.filteredItems == expected.items }
        precondition(model.selectedIDs == [expected.items[0].id] && copies == 0 && scrolls == 0)
        print("PASS: pending and cancelled searches retain displayed rows and highlight, do not copy stale results, and apply only the latest result without scrolling")

        model.query = "Fixture"
        try await waitUntil { !model.isLoading && model.resultCount == 610 }
        let sameItems = model.filteredItems
        var changedRows = 0
        let rows = model.$filteredItems.dropFirst().sink { _ in changedRows += 1 }
        model.query = "Fixture App"
        try await Task.sleep(for: .milliseconds(200))
        try await waitUntil { !model.isLoading }
        precondition(model.filteredItems == sameItems && changedRows == 0 && model.scrollToStartToken == 0)
        print("PASS: refining a keyword with identical matches does not republish or replace the displayed rows")
        model.query = ""
        try await waitUntil { !model.isLoading && model.scrollToStartToken == 1 }
        precondition(model.filteredItems == sameItems && changedRows == 0 && scrolls == 0,
                     "Clearing search must reset scrolling even when its first page is unchanged")
        rows.cancel()
        print("PASS: clearing search resets scrolling without republishing identical rows or sending a keyboard scroll")

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

        let beforePaging = model.scrollToStartToken
        model.query = "Fixture"
        try await waitUntil { !model.isLoading && model.resultCount == 610 }
        model.loadNextPage()
        try await waitUntil { !model.isLoading && model.filteredItems.count == 400 }
        precondition(model.scrollToStartToken == beforePaging, "Searching and pagination must not reset scrolling")
        model.selectForClick(model.filteredItems[250])
        let pagedItems = model.filteredItems
        let pagedSelection = model.selectedIDs
        let clearGate = manager.pauseStorage()
        let clearBlocker = Task { try await repository.deleteItems([UUID()]) }
        await Task.detached { precondition(clearGate.started.wait(timeout: .now() + 5) == .success) }.value
        model.query = ""
        try await waitUntil { model.isLoading }
        precondition(model.filteredItems == pagedItems && model.selectedIDs == pagedSelection
                     && model.scrollToStartToken == beforePaging,
                     "Clearing search must wait for the new first page before resetting scrolling")
        clearGate.resume.signal()
        try await clearBlocker.value
        try await waitUntil { !model.isLoading && model.scrollToStartToken == beforePaging + 1 }
        precondition(model.filteredItems == originalItems && model.selectedIDs == [originalItems[0].id])
        await repository.reload()
        try await waitUntil { !model.isLoading }
        precondition(model.scrollToStartToken == beforePaging + 1 && scrolls == 0,
                     "Refreshing the cleared query must not reset scrolling again")
        print("PASS: clearing a paginated search waits for its first page, resets once, and leaves refreshes stationary")

        model.query = "Record"
        try await waitUntil { !model.isLoading && model.resultCount == 366 }
        let beforeCancelledClear = model.scrollToStartToken
        let cancelledGate = manager.pauseStorage()
        let cancelledBlocker = Task { try await repository.deleteItems([UUID()]) }
        await Task.detached { precondition(cancelledGate.started.wait(timeout: .now() + 5) == .success) }.value
        model.query = ""
        try await waitUntil { model.isLoading }
        model.query = "Record 2"
        try await Task.sleep(for: .milliseconds(150))
        cancelledGate.resume.signal()
        try await cancelledBlocker.value
        try await waitUntil { !model.isLoading && model.filteredItems == expected.items }
        precondition(model.scrollToStartToken == beforeCancelledClear && scrolls == 0,
                     "A cancelled clear must not reset scrolling for the replacement search")
        print("PASS: replacing a pending clear with another search discards its scroll reset")

        model.query = "Record"
        try await waitUntil { !model.isLoading && model.resultCount == 366 }
        let beforeRepeatedClear = model.scrollToStartToken
        var replacedClear = false
        let repeatedClear = model.$resultCount.sink { count in
            guard count == 610, !replacedClear else { return }
            replacedClear = true
            // Change the text after the cleared rows arrive, before their scroll reset is evaluated.
            model.query = "Record 2"
        }
        model.query = ""
        try await waitUntil { replacedClear && !model.isLoading && model.resultCount == 610 }
        precondition(model.query == "Record 2" && model.scrollToStartToken == beforeRepeatedClear,
                     "A newer input must suppress the old clear's scroll reset")
        // Clear again before the replacement text reaches its debounce, leaving the same debounced query.
        model.query = ""
        try await waitUntil { !model.isLoading && model.scrollToStartToken == beforeRepeatedClear + 1 }
        repeatedClear.cancel()
        precondition(model.filteredItems == originalItems && scrolls == 0)
        print("PASS: clearing again before new input is applied still resets once after the previous clear was suppressed")

        let group = try await repository.saveGroup(name: "Search clearing")
        let groupedEntries = Array(batch.entries.prefix(100))
        try await repository.setGroup(group.id, for: Set(groupedEntries.map { $0.item.id }), included: true)
        model.query = "No matching fixture"
        model.contentFilter = .text
        model.sourceFilter = "Fixture App 0"
        model.groupFilter = .group(group.id)
        try await waitUntil { !model.isLoading && model.filteredItems.isEmpty }
        let beforeEmptyClear = model.scrollToStartToken
        model.query = ""
        try await waitUntil { !model.isLoading && model.scrollToStartToken == beforeEmptyClear + 1 }
        let filteredIDs = Set(groupedEntries.filter {
            $0.item.type == .text && $0.item.sourceAppName == "Fixture App 0"
        }.map { $0.item.id })
        precondition(!filteredIDs.isEmpty && Set(model.filteredItems.map(\.id)) == filteredIDs)
        precondition(model.contentFilter == .text && model.sourceFilter == "Fixture App 0"
                     && model.groupFilter == .group(group.id) && scrolls == 0,
                     "Clearing an empty search must preserve type, source, and group filters")
        print("PASS: clearing an empty search resets scrolling and preserves the combined type, source, and group filters")

        let emptyGroup = try await repository.saveGroup(name: "Empty search clearing")
        model.query = "No matching fixture"
        model.groupFilter = .group(emptyGroup.id)
        try await waitUntil { !model.isLoading && model.filteredItems.isEmpty }
        let beforeStillEmptyClear = model.scrollToStartToken
        model.query = " \n "
        try await waitUntil { !model.isLoading && model.scrollToStartToken == beforeStillEmptyClear + 1 }
        precondition(model.filteredItems.isEmpty && model.selectedIDs.isEmpty && scrolls == 0,
                     "Whitespace-only search must clear the old scroll anchor even when the result stays empty")
        precondition(model.contentFilter == .text && model.sourceFilter == "Fixture App 0"
                     && model.groupFilter == .group(emptyGroup.id))
        print("PASS: clearing to whitespace also resets an empty result without a selection or keyboard scroll")
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        precondition(condition(), "Timed out")
    }
}
