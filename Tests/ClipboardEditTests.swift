import AppKit
import Combine

@main
@MainActor
struct ClipboardEditTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLite-edit-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try await run(root: root)
    }

    private static func run(root: URL) async throws {
        let manager = PerformanceFileManager(root: root)
        let repository = ClipboardRepository(fileManager: manager)
        try await waitUntil { repository.isReady }
        let originalCapture = capture("Original body")
        repository.record(originalCapture)
        try await waitUntil { repository.totalCount == 1 }
        let original = repository.items[0]
        let group = try await repository.saveGroup(name: "Editing")
        try await repository.setGroups([group.id], for: original.id)
        let model = ClipboardViewModel(repository: repository)
        model.groupFilter = .group(group.id)
        try await waitUntil { model.filteredItems.count == 1 && !model.isLoading }
        model.select(original)
        var scrollCount = 0
        let subscription = model.keyboardScrollRequests.sink { _ in scrollCount += 1 }
        defer { subscription.cancel() }
        let updatedText = "Changed body\n" + String(repeating: "完整正文 👩🏽‍💻\n", count: 2_000)
        try await repository.editItem(id: original.id, title: "  Edited title  ", textContent: updatedText)
        try await waitUntil { model.filteredItems.first?.customTitle == "Edited title" && !model.isLoading }
        let updated = try await repository.item(id: original.id)!
        precondition(updated.textContent == updatedText && updated.contentHash == PreparedCapture.prepare(capture(updatedText))!.contentHash)
        precondition(updated.customTitle == "Edited title" && updated.groupIDs == [group.id])
        precondition(updated.createdAt == original.createdAt && updated.lastCopiedAt == original.lastCopiedAt)
        precondition(updated.sourceAppName == original.sourceAppName && updated.sourceBundleID == original.sourceBundleID)
        precondition(model.selectedID == original.id && scrollCount == 0 && model.filteredItems[0].textContent == String(updatedText.prefix(200)))
        let oldSearch = try await repository.query(ClipboardQuery(text: "Original body"))
        let newSearch = try await repository.query(ClipboardQuery(text: "完整正文", group: .group(group.id)))
        precondition(oldSearch.total == 0 && newSearch.items.map(\.id) == [original.id])
        let emptyBatch = PasteImportBatch(directory: root.appendingPathComponent("empty-batch"), entries: [], total: 0, duplicates: 0, skipped: [:])
        let storagePreview = try await repository.previewImport(emptyBatch)
        precondition(storagePreview.existingBytes == Int64(updatedText.utf8.count))
        let reopened = ClipboardRepository(fileManager: manager)
        try await waitUntil { reopened.isReady }
        let persisted = try await reopened.item(id: original.id)
        precondition(persisted == updated)
        print("PASS: full-body edit persists title, summary, hash and byte count; preserves identity, timestamps, source, groups and selection without scrolling")

        let pasteboard = NSPasteboard(name: .init("PasteLite-edit-tests-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardMonitor(repository: repository, pasteboard: pasteboard)
        let service = PasteService(repository: repository, monitor: monitor, pasteboard: pasteboard)
        precondition(service.writeToPasteboard(updated))
        precondition(pasteboard.string(forType: .string) == updatedText)
        await repository.reload()
        let revision = repository.revision
        repository.record(capture(updatedText))
        try await waitUntil { repository.revision > revision }
        precondition(repository.totalCount == 1)
        repository.record(originalCapture)
        try await waitUntil { repository.totalCount == 2 }
        let beforeDuplicate = try await repository.item(id: original.id)!
        do {
            try await repository.editItem(id: original.id, title: "Should not save", textContent: "Original body")
            preconditionFailure("Duplicate accepted")
        } catch ClipboardEditError.duplicateContent {}
        let afterDuplicate = try await repository.item(id: original.id)
        precondition(afterDuplicate == beforeDuplicate && repository.totalCount == 2)
        print("PASS: edited text is copied intact; deduplication uses new content; a conflicting edit never overwrites either record")

        for (text, expected) in [("", ClipboardEditError.emptyContent), (String(repeating: "界", count: 1_400_000), .tooLarge)] {
            do { try await repository.editItem(id: original.id, title: "Should not save", textContent: text); preconditionFailure("Invalid body accepted") }
            catch { precondition(String(describing: error) == String(describing: expected)) }
        }
        do { try await repository.editItem(id: original.id, title: "two\nlines", textContent: "Should not save"); preconditionFailure("Invalid title accepted") }
        catch ClipboardTitleError.invalidTitle {}
        let afterInvalid = try await repository.item(id: original.id)
        precondition(afterInvalid == beforeDuplicate)
        do { try await repository.editItem(id: UUID(), title: "Missing", textContent: "Missing"); preconditionFailure("Missing record recreated") }
        catch ClipboardTitleError.missingRecord {}

        repository.record(capture("https://example.com/old", type: .url))
        try await waitUntil { repository.totalCount == 3 }
        let url = try await repository.query(ClipboardQuery(type: "url")).items[0]
        try await repository.editItem(id: url.id, title: "Updated link", textContent: "https://example.com/new?q=test")
        for invalid in ["not a url", "relative/path", "https://example.com/\nline"] {
            do { try await repository.editItem(id: url.id, title: "Should not save", textContent: invalid); preconditionFailure("Invalid URL accepted") }
            catch ClipboardEditError.invalidURL {}
        }
        let updatedURL = try await repository.item(id: url.id)!
        precondition(service.writeToPasteboard(updatedURL))
        precondition(pasteboard.string(forType: .URL) == "https://example.com/new?q=test")
        print("PASS: empty/oversized text, invalid titles/URLs and missing records are rejected atomically; edited links retain URL paste behavior")

        let fixtures = try PerformanceFixtures.makeBatch(count: 10, root: root)
        var entries = fixtures.entries
        let importedTitle = String(repeating: "长标题", count: 60)
        entries[0].item.customTitle = importedTitle
        let batch = PasteImportBatch(directory: fixtures.directory, entries: entries, total: entries.count, duplicates: 0, skipped: [:])
        _ = try await repository.importBatch(batch, preview: repository.previewImport(batch), expand: false)
        try await repository.editItem(id: entries[0].item.id, title: importedTitle, textContent: "Imported body edited")
        let imported = try await repository.item(id: entries[0].item.id)
        precondition(imported?.customTitle == importedTitle && imported?.textContent == "Imported body edited")
        for type in [ClipboardContentType.image, .file] {
            let original = entries.first { $0.item.type == type }!.item
            try await repository.editItem(id: original.id, title: "Media title", textContent: nil)
            do { try await repository.editItem(id: original.id, title: "Should not save", textContent: "Not supported"); preconditionFailure("Media body changed") }
            catch ClipboardEditError.unsupportedContent {}
            let edited = try await repository.item(id: original.id)!
            precondition(edited.customTitle == "Media title" && edited.contentHash == original.contentHash)
            precondition(edited.assetFilename == original.assetFilename && edited.filePaths == original.filePaths)
            precondition(service.writeToPasteboard(edited))
        }
        try await repository.editItem(id: original.id, title: "", textContent: nil)
        let auto = try await repository.item(id: original.id)!
        precondition(auto.customTitle == nil && auto.displayTitle == "Changed body")
        await repository.reload()
        try await waitUntil { !model.isLoading }
        print("PASS: imported long titles survive body edits, media title editing preserves original assets, and clearing title restores automatic title")
    }

    private static func capture(_ text: String, type: ClipboardContentType = .text) -> ClipboardCapture {
        ClipboardCapture(type: type, textContent: text, imageData: nil, filePaths: [], sourceAppName: "Fixture", sourceBundleID: "example.fixture", capturedAt: Date())
    }

    private static func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out")
    }
}
