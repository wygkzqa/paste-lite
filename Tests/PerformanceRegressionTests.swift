import Foundation

@main
@MainActor
struct PerformanceRegressionTests {
    static func main() async throws {
        UserDefaults.standard.setVolatileDomain([L10n.languageDefaultsKey: "en"], forName: UserDefaults.argumentDomain)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLite-performance-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ClipboardRepository(fileManager: PerformanceFileManager(root: root))
        let fixture = try PerformanceFixtures.makeBatch(count: 1_000, root: root)
        var entries = fixture.entries
        entries[0].item.textContent = "\n \tHeading\n" + String(repeating: "body content ", count: 20_000) + "unique-tail-needle"
        entries[1].item.textContent = String(repeating: "中文🙂", count: 5_000)
        let batch = PasteImportBatch(directory: fixture.directory, entries: entries, total: entries.count, duplicates: 0, skipped: [:])
        let preview = try await repository.previewImport(batch)
        _ = try await repository.importBatch(batch, preview: preview, expand: true)
        let model = ClipboardViewModel(repository: repository)
        try await waitUntil { model.resultCount == 1_000 && model.filteredItems.count == ClipboardRepository.pageSize }
        precondition(entries[0].item.displayTitle == "Heading")
        precondition(entries[1].item.displayTitle.count == 200)
        model.query = "unique-tail-needle"
        try await waitUntil { model.filteredItems.count == 1 }
        precondition(model.filteredItems[0].id == entries[0].item.id)
        let fullItem = try await repository.item(id: model.filteredItems[0].id)
        precondition(fullItem?.textContent == entries[0].item.textContent)
        precondition(model.filteredItems[0].textContent!.count <= 200)
        print("PASS: bounded Unicode titles keep full text searchable and unchanged")

        model.query = "unmatched-query"
        try await Task.sleep(for: .milliseconds(110))
        model.query = "Fixture App 9"
        model.sourceFilter = "Fixture App 9"
        model.contentFilter = .file
        try await waitUntil { model.filteredItems.count == 50 }
        precondition(model.filteredItems.allSatisfy { $0.sourceAppName == "Fixture App 9" && $0.type == .file })
        try await Task.sleep(for: .milliseconds(200))
        precondition(model.filteredItems.count == 50)
        print("PASS: latest query and type/source filters win over cancelled background searches")

        var unseen = entries[0].item
        unseen.lastCopiedAt = Date().addingTimeInterval(-59)
        model.prepareForPresentation(hasAccessibilityPermission: true)
        let token = model.presentationToken
        try await Task.sleep(for: .milliseconds(1_100))
        precondition(model.timeLabel(for: unseen) == "Just now")
        precondition(model.presentationToken == token)
        model.prepareForPresentation(hasAccessibilityPermission: true)
        precondition(model.timeLabel(for: unseen) == "1 min ago")
        print("PASS: first rendering after scrolling uses the opening snapshot, not the current clock")

        let imageURL = fixture.directory.appendingPathComponent("image-0.png")
        let missingURL = fixture.directory.appendingPathComponent("missing.png")
        let fallback = await ClipboardImageLoader.load(from: missingURL, fallbackURL: imageURL, maxPixelSize: 128)
        precondition(fallback != nil && fallback!.width <= 128)
        let existingFile = await ClipboardFileStatus.filesExist([imageURL.path])
        let missingFile = await ClipboardFileStatus.filesExist([missingURL.path])
        precondition(existingFile == true && missingFile == false)
        let tasks = (0..<500).map { index in
            Task.detached { await ClipboardImageLoader.load(from: fixture.directory.appendingPathComponent("image-\(index % 512).png"), maxPixelSize: 128) }
        }
        try await Task.sleep(for: .milliseconds(1))
        for task in tasks { task.cancel() }
        var cancelled = 0
        for task in tasks { if await task.value == nil { cancelled += 1 } }
        precondition(cancelled > 0)
        let finalImage = await ClipboardImageLoader.load(from: imageURL, maxPixelSize: 128)
        precondition(finalImage != nil)
        print("PASS: missing thumbnails fall back to originals; file checks work; 500 cancelled loads drain without hangs")
        withExtendedLifetime(fixture) {}
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        precondition(condition(), "Timed out")
    }
}
