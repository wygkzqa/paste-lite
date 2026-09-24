import AppKit
import Combine
import Foundation

@main
@MainActor
struct ClipboardTitleTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLite-title-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try await run(root: root)
    }

    private static func run(root: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ".build/tests/pre-title-history-fixture")
        process.arguments = [root.path]
        try process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        let manager = PerformanceFileManager(root: root)
        let repository = ClipboardRepository(fileManager: manager)
        try await waitUntil { repository.totalCount == 205 || repository.errorMessage != nil }
        precondition(repository.errorMessage == nil && repository.groups.count == 1)
        precondition(repository.items.allSatisfy { $0.customTitle == nil && $0.displayTitle == $0.automaticTitle })
        let groupID = repository.groups[0].id
        let model = ClipboardViewModel(repository: repository)
        model.groupFilter = .group(groupID)
        try await waitUntil { model.filteredItems.count == 200 && !model.isLoading }
        model.loadNextPage()
        try await waitUntil { model.filteredItems.count == 205 && !model.isLoading }
        let original = model.filteredItems.last!
        model.select(original)
        var scrolls = 0
        let subscription = model.keyboardScrollRequests.sink { _ in scrolls += 1 }
        defer { subscription.cancel() }
        try await repository.renameTitle(id: original.id, title: "  启动服务 👩🏽‍💻  ")
        try await waitUntil { !model.isLoading && model.filteredItems.last?.customTitle == "启动服务 👩🏽‍💻" }
        precondition(model.filteredItems.count == 205 && model.selectedID == original.id && scrolls == 0)
        let updated = try await repository.item(id: original.id)!
        precondition(updated.displayTitle == "启动服务 👩🏽‍💻" && updated.textContent == original.textContent)
        precondition(updated.createdAt == original.createdAt && updated.lastCopiedAt == original.lastCopiedAt)
        precondition(updated.groupIDs == original.groupIDs && updated.contentHash == original.contentHash)
        let query = ClipboardQuery(text: "启动服务", type: "text", source: "Fixture", group: .group(groupID))
        let found = try await repository.query(query)
        precondition(found.items.map(\.id) == [original.id])
        let byContent = try await repository.query(ClipboardQuery(text: original.textContent!))
        precondition(byContent.items.contains { $0.id == original.id })
        let reopened = ClipboardRepository(fileManager: manager)
        try await waitUntil { reopened.isReady }
        let persisted = try await reopened.item(id: original.id)
        precondition(persisted?.customTitle == updated.customTitle)
        print("PASS: pre-title store migration, group preservation, persistent full-library title search, and rename beyond page 1 without scrolling")

        model.query = "启动服务"
        try await waitUntil { model.filteredItems.count == 1 && !model.isLoading }
        try await repository.renameTitle(id: original.id, title: "另一个标题")
        try await waitUntil { model.filteredItems.isEmpty && !model.isLoading }
        let oldQuery = try await repository.query(query)
        precondition(oldQuery.total == 0 && model.query == "启动服务" && model.groupFilter == .group(groupID))
        try await repository.renameTitle(id: original.id, title: " \n ")
        let reset = try await repository.item(id: original.id)!
        precondition(reset.customTitle == nil && reset.displayTitle == original.displayTitle)
        for invalid in [String(repeating: "字", count: 101), "two\nlines", "two\rlines", "two\u{2028}lines"] {
            do { try await repository.renameTitle(id: original.id, title: invalid); preconditionFailure("Invalid title accepted") }
            catch ClipboardTitleError.invalidTitle {}
        }
        let emojiTitle = String(repeating: "👨‍👩‍👧‍👦", count: 100)
        try await repository.renameTitle(id: original.id, title: emojiTitle)
        let emojiRecord = try await repository.item(id: original.id)
        precondition(emojiRecord?.customTitle == emojiTitle)
        do { try await repository.renameTitle(id: UUID(), title: "Missing"); preconditionFailure("Missing record recreated") }
        catch ClipboardTitleError.missingRecord {}
        print("PASS: cached search refresh, restore automatic title, Unicode character limit, line-break rejection and missing-record error")

        // Old JSON has neither customTitle nor groupIDs.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        json.removeValue(forKey: "customTitle")
        json.removeValue(forKey: "groupIDs")
        let decoded = try JSONDecoder().decode(ClipboardItem.self, from: JSONSerialization.data(withJSONObject: json))
        precondition(decoded.customTitle == nil && decoded.displayTitle == original.automaticTitle)
        print("PASS: title-less legacy JSON remains decodable")

        let capture = ClipboardCapture(type: .text, textContent: "pnpm dev --host 0.0.0.0", imageData: nil, filePaths: [],
            sourceAppName: "Fixture", sourceBundleID: "example.fixture", capturedAt: Date())
        repository.record(capture)
        try await waitUntil { repository.totalCount == 206 }
        let captured = repository.items[0]
        try await repository.renameTitle(id: captured.id, title: "开发服务")
        let revision = repository.revision
        repository.record(capture)
        try await waitUntil { repository.revision > revision }
        let renamed = try await repository.item(id: captured.id)!
        precondition(renamed.customTitle == "开发服务")
        let pasteboard = NSPasteboard(name: .init("PasteLite-title-tests-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardMonitor(repository: repository, pasteboard: pasteboard)
        let service = PasteService(repository: repository, monitor: monitor, pasteboard: pasteboard)
        precondition(service.writeToPasteboard(renamed))
        precondition(pasteboard.string(forType: .string) == capture.textContent)

        let batch = try PerformanceFixtures.makeBatch(count: 10, root: root)
        let preview = try await repository.previewImport(batch)
        _ = try await repository.importBatch(batch, preview: preview, expand: false)
        for type in ClipboardContentType.allCases {
            let entry = batch.entries.first { $0.item.type == type }!
            try await repository.renameTitle(id: entry.item.id, title: "相同标题")
            let full = try await repository.item(id: entry.item.id)!
            precondition(full.customTitle == "相同标题" && full.textContent == entry.item.textContent && full.filePaths == entry.item.filePaths)
            precondition(service.writeToPasteboard(full))
            if type == .url { precondition(pasteboard.string(forType: .URL) == full.textContent) }
            if type == .file { precondition(pasteboard.string(forType: .fileURL) == URL(fileURLWithPath: full.filePaths[0]).absoluteString) }
            if type == .image { precondition(NSImage(pasteboard: pasteboard) != nil) }
        }
        let sameNames = try await repository.query(ClipboardQuery(text: "相同标题"))
        precondition(sameNames.total == 4)
        // Let the final named-pasteboard write finish its metadata refresh before teardown.
        await repository.reload()
        try await waitUntil { !model.isLoading }
        print("PASS: repeated capture retains title; all four types support shared titles and write original payloads to an isolated pasteboard")
    }

    private static func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Timed out")
    }
}
