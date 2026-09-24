import AppKit
import Combine

private final class SelectionFileManager: FileManager, @unchecked Sendable {
    let root: URL
    var failingFilename: String?
    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        directory == .applicationSupportDirectory ? [root] : super.urls(for: directory, in: domainMask)
    }
    override func removeItem(at url: URL) throws {
        if url.lastPathComponent == failingFilename { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: url)
    }
}

@main
@MainActor
struct ClipboardSelectionTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLite-selection-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try await run(root: root)
    }

    private static func run(root: URL) async throws {
        let manager = SelectionFileManager(root: root.appendingPathComponent("destination"))
        let repository = ClipboardRepository(fileManager: manager)
        try await waitUntil { repository.isReady }
        let fixture = try PerformanceFixtures.makeBatch(count: 610, root: root)
        var entries = fixture.entries
        entries[7].item.assetFilename = entries[6].item.assetFilename
        entries[7].item.thumbnailFilename = entries[6].item.thumbnailFilename
        let batch = PasteImportBatch(directory: fixture.directory, entries: entries, total: entries.count, duplicates: 0, skipped: [:])
        let preview = try await repository.previewImport(batch)
        _ = try await repository.importBatch(batch, preview: preview, expand: false)
        let firstGroup = try await repository.saveGroup(name: "First group")
        let secondGroup = try await repository.saveGroup(name: "Second group")
        let grouped = Set(entries.prefix(503).map(\.item.id))
        try await repository.setGroup(firstGroup.id, for: grouped, included: true)
        let model = ClipboardViewModel(repository: repository)
        try await waitUntil { model.filteredItems.count == 200 && !model.isLoading }
        var scrolls = 0
        let subscription = model.keyboardScrollRequests.sink { _ in scrolls += 1 }
        defer { subscription.cancel() }
        let visible = model.filteredItems
        model.selectForClick(visible[20])
        model.selectForClick(visible[25], extending: true)
        precondition(model.selectedIDs == Set(visible[20...25].map(\.id)))
        model.selectForClick(visible[22], extending: true)
        precondition(model.selectedIDs == Set(visible[20...22].map(\.id)))
        model.selectForClick(visible[10], toggling: true)
        precondition(model.selectedIDs.count == 4)
        model.selectForContextMenu(visible[21])
        precondition(model.selectedIDs.count == 4 && model.selectedID == visible[21].id)
        model.selectForContextMenu(visible[11])
        precondition(model.selectedIDs == [visible[11].id] && scrolls == 0)
        model.selectForClick(visible[11], toggling: true)
        precondition(model.selectedIDs.isEmpty && model.selectedItem == nil)
        print("PASS: command toggles, shift range expands/contracts, right-click preserves selected sets or selects an outside row, and mouse selection never scrolls")

        model.select(visible.last!)
        model.moveSelection(by: 1, extending: true)
        try await waitUntil { model.filteredItems.count == 400 && !model.isLoading }
        precondition(model.selectedIDs == [model.filteredItems[199].id, model.filteredItems[200].id] && scrolls == 1)
        model.moveSelection(by: -1, extending: true)
        precondition(model.selectedIDs == [model.filteredItems[199].id])
        print("PASS: shift-arrow selection crosses page boundaries and only keyboard selection scrolls")

        for action in ["click", "command-click", "shift-click", "context menu", "reopen"] {
            let pagingModel = ClipboardViewModel(repository: repository)
            try await waitUntil { pagingModel.filteredItems.count == 200 && !pagingModel.isLoading }
            var pageScrolls = 0
            let pageSubscription = pagingModel.keyboardScrollRequests.sink { _ in pageScrolls += 1 }
            let first = pagingModel.filteredItems.first!
            let last = pagingModel.filteredItems.last!
            pagingModel.select(last)
            pagingModel.moveSelection(by: 1, extending: true)
            // Change selection before yielding to the asynchronous page fetch.
            switch action {
            case "click": pagingModel.selectForClick(first)
            case "command-click": pagingModel.selectForClick(first, toggling: true)
            case "shift-click": pagingModel.selectForClick(first, extending: true)
            case "context menu": pagingModel.selectForContextMenu(last)
            default: pagingModel.prepareForPresentation(hasAccessibilityPermission: false)
            }
            let selected = pagingModel.selectedIDs
            let focused = pagingModel.selectedID
            let memberships = pagingModel.selectionForContextMenu
            try await waitUntil { pagingModel.filteredItems.count == 400 && !pagingModel.isLoading }
            precondition(pagingModel.selectedIDs == selected && pagingModel.selectedID == focused,
                         "Pending keyboard navigation overwrote \(action)")
            precondition(pagingModel.selectionForContextMenu == memberships && pageScrolls == 0)
            pageSubscription.cancel()
        }
        print("PASS: pending keyboard pagination preserves later clicks, range/toggle selections, context-menu selection and reopening without scrolling")

        model.groupFilter = .group(firstGroup.id)
        model.contentFilter = .text
        model.query = "Record"
        try await waitUntil { model.filteredItems.count == 200 && model.resultCount > 200 && !model.isLoading }
        let expected = Set(entries.prefix(503).filter { $0.item.type == .text }.map(\.item.id))
        model.selectAll()
        try await waitUntil { !model.isSelectingAll && model.selectedIDs == expected }
        precondition(model.filteredItems.count == 200 && model.selectionForContextMenu.count == expected.count)
        precondition(model.selectionForContextMenu.values.allSatisfy { $0 == [firstGroup.id] })
        let before = try await repository.item(id: entries[0].item.id)!
        try await repository.setGroup(secondGroup.id, for: model.selectedIDs, included: true)
        try await waitUntil { !model.isLoading && model.selectionForContextMenu.values.allSatisfy { $0.contains(secondGroup.id) } }
        precondition(model.selectedIDs == expected && model.filteredItems.count == 200)
        let after = try await repository.item(id: entries[0].item.id)!
        precondition(after.createdAt == before.createdAt && after.lastCopiedAt == before.lastCopiedAt && after.contentHash == before.contentHash)
        precondition(Set(after.groupIDs ?? []) == [firstGroup.id, secondGroup.id])
        try await repository.setGroup(secondGroup.id, for: expected, included: false)
        try await waitUntil { !model.isLoading && model.selectionForContextMenu.values.allSatisfy { !$0.contains(secondGroup.id) } }
        print("PASS: select all includes filtered off-page IDs without loading all rows; batch group changes preserve other memberships, metadata and the full selection")

        do { try await repository.setGroup(secondGroup.id, for: expected.union([UUID()]), included: true); preconditionFailure("Missing record accepted") }
        catch ClipboardGroupError.missingRecord {}
        let unchangedGroups = try await repository.selection(for: ClipboardQuery(group: .group(secondGroup.id)))
        precondition(unchangedGroups.isEmpty)
        do { try await repository.setGroup(UUID(), for: expected, included: true); preconditionFailure("Missing group accepted") }
        catch ClipboardGroupError.missingRecord {}
        print("PASS: missing groups or records roll back the entire batch membership change")

        let clipboard = NSPasteboard(name: .init("PasteLite-selection-tests-\(UUID())"))
        defer { clipboard.releaseGlobally() }
        clipboard.setString("Keep clipboard", forType: .string)
        let base = manager.root.appendingPathComponent("PasteLite")
        let legacy = base.appendingPathComponent("history.json")
        try Data("Legacy input".utf8).write(to: legacy)
        manager.failingFilename = "history.json"
        do { try await repository.deleteItems(expected); preconditionFailure("Storage failure ignored") }
        catch ClipboardDeleteError.failed {}
        precondition(repository.totalCount == 610 && FileManager.default.fileExists(atPath: legacy.path))
        manager.failingFilename = nil
        try await repository.deleteItems(expected)
        try await waitUntil { model.resultCount == 0 && !model.isLoading }
        precondition(repository.totalCount == 610 - expected.count && model.selectedIDs.isEmpty)
        precondition(repository.groups.count == 2 && repository.limits == .default)
        precondition(!FileManager.default.fileExists(atPath: legacy.path))
        precondition(clipboard.string(forType: .string) == "Keep clipboard")
        let deletedSearch = try await repository.query(ClipboardQuery(text: "Record", type: "text", group: .group(firstGroup.id)))
        precondition(deletedSearch.total == 0)
        print("PASS: bulk deletion is atomic on storage failure, invalidates search/selection, preserves settings/groups/current clipboard, and removes migration replay input")

        let sharedImage = entries[6].item
        let sharedAsset = repository.assetURL(for: sharedImage)!
        let sharedThumbnail = repository.previewURL(for: sharedImage)!
        try await repository.deleteItems([sharedImage.id])
        precondition(FileManager.default.fileExists(atPath: sharedAsset.path) && FileManager.default.fileExists(atPath: sharedThumbnail.path))
        try await repository.deleteItems([entries[7].item.id])
        precondition(!FileManager.default.fileExists(atPath: sharedAsset.path) && !FileManager.default.fileExists(atPath: sharedThumbnail.path))
        let file = entries[9].item
        try await repository.deleteItems([file.id])
        precondition(FileManager.default.fileExists(atPath: file.filePaths[0]))
        let failingImage = entries[16].item
        let failedAsset = repository.assetURL(for: failingImage)!
        manager.failingFilename = failedAsset.lastPathComponent
        do { try await repository.deleteItems([failingImage.id]); preconditionFailure("File cleanup failure ignored") }
        catch ClipboardDeleteError.filesRemain {}
        let deleted = try await repository.item(id: failingImage.id)
        precondition(deleted == nil && FileManager.default.fileExists(atPath: failedAsset.path) && !repository.isDeletingItems)
        manager.failingFilename = nil
        print("PASS: shared assets survive until their last reference is deleted, external files remain untouched, and partial asset-cleanup failure is reported after history refresh")

        model.query = "fixture.txt"
        model.groupFilter = .all
        model.contentFilter = .all
        model.selectAll()
        try await waitUntil { !model.isSelectingAll && !model.isLoading && model.resultCount > 0 }
        let fileMatches = try await repository.selection(for: ClipboardQuery(text: "fixture.txt"))
        precondition(model.selectedIDs == Set(fileMatches.keys))
        model.query = "No matching result"
        try await waitUntil { model.resultCount == 0 && !model.isLoading }
        precondition(model.selectedIDs.isEmpty && !model.isSelectingAll)
        let remaining = try await repository.selection(for: ClipboardQuery())
        try await repository.deleteItems(Set(remaining.keys))
        let reopened = ClipboardRepository(fileManager: manager)
        try await waitUntil { reopened.isReady }
        precondition(reopened.totalCount == 0 && reopened.groups.count == 2)
        await repository.reload()
        try await waitUntil { !model.isLoading }
        print("PASS: select all honors pending search text, filter changes clear hidden selections, and deleting all selected history persists across restart")
    }

    private static func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out")
    }
}
