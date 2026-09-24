import AppKit
import Foundation

private final class ClearHistoryFileManager: FileManager, @unchecked Sendable {
    let root: URL
    var failingFilename: String?
    var beforeRemove: (() -> Void)?

    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        directory == .applicationSupportDirectory ? [root] : super.urls(for: directory, in: domainMask)
    }
    override func removeItem(at url: URL) throws {
        let callback = beforeRemove
        beforeRemove = nil
        callback?()
        if url.lastPathComponent == failingFilename { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: url)
    }
}

@main
@MainActor
struct ClearHistoryTests {
    static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLite-clear-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ClearHistoryFileManager(root: root.appendingPathComponent("destination"))
        let repository = ClipboardRepository(fileManager: manager)
        try await waitUntil { repository.isReady }
        let batch = try PerformanceFixtures.makeBatch(count: 1_005, root: root)
        let initial = try await repository.previewImport(batch)
        _ = try await repository.importBatch(batch, preview: initial, expand: false)
        let group = try await repository.saveGroup(name: "Keep this group")
        let first = repository.items[0]
        try await repository.setGroups([group.id], for: first.id)
        let limits = ClipboardLimits(itemCount: 10_000, retentionDays: 90)
        try await repository.updateLimits(limits)
        let model = ClipboardViewModel(repository: repository)
        model.groupFilter = .group(group.id)
        try await waitUntil { model.resultCount == 1 }
        let source = try await repository.query(ClipboardQuery(text: "Record"))
        precondition(source.total > 0)
        let image = repository.items.first { $0.type == .image }!
        let imageURL = repository.assetURL(for: image)!
        let cachedImage = await ClipboardImageLoader.load(from: imageURL, maxPixelSize: 64)
        precondition(cachedImage != nil)
        let base = manager.root.appendingPathComponent("PasteLite")
        let legacy = base.appendingPathComponent("history.json")
        let backup = base.appendingPathComponent("history.v1.backup.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacyData = try encoder.encode([first])
        try legacyData.write(to: legacy)
        try legacyData.write(to: backup)
        let staleImport = try await repository.previewImport(batch)
        let pasteboard = NSPasteboard(name: .init("PasteLite-clear-test-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardMonitor(repository: repository, pasteboard: pasteboard)
        monitor.start()
        defer { monitor.stop() }
        pasteboard.setString("Keep current clipboard", forType: .string)
        let gate = DispatchSemaphore(value: 0)
        manager.beforeRemove = {
            Task { @MainActor in
                precondition(repository.isClearingHistory)
                repository.record(capture("Do not restore history during clear"))
                do { try await repository.clearHistory(); preconditionFailure("Overlapping clear accepted") }
                catch ClipboardHistoryClearError.busy {}
                catch { preconditionFailure("Unexpected clear error") }
                do { try await repository.updateLimits(.default); preconditionFailure("Settings changed during clear") }
                catch PasteImportError.storage {}
                catch { preconditionFailure("Unexpected settings error") }
                do { _ = try await repository.importBatch(batch, preview: staleImport, expand: false); preconditionFailure("Import overlapped clear") }
                catch PasteImportError.storage {}
                catch { preconditionFailure("Unexpected import error") }
                gate.signal()
            }
            precondition(gate.wait(timeout: .now() + 10) == .success)
        }
        try await monitor.clearHistory()
        ClipboardImageLoader.clearCache()
        precondition(repository.totalCount == 0 && repository.items.isEmpty && repository.sourceApps.isEmpty)
        precondition(repository.groups == [group] && repository.limits == limits && !repository.isClearingHistory)
        try await waitUntil { model.resultCount == 0 && model.selectedID == nil }
        precondition(model.groupFilter == .group(group.id))
        let emptySearch = try await repository.query(ClipboardQuery(text: "Record"))
        precondition(emptySearch.total == 0)
        for directory in ["Assets", "Thumbnails"] {
            let files = try FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent(directory).path)
            precondition(files.isEmpty)
        }
        precondition(!FileManager.default.fileExists(atPath: legacy.path) && !FileManager.default.fileExists(atPath: backup.path))
        precondition(FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture.txt").path))
        precondition(FileManager.default.fileExists(atPath: batch.directory.appendingPathComponent(image.assetFilename!).path))
        let removedImage = await ClipboardImageLoader.load(from: imageURL, maxPixelSize: 64)
        precondition(removedImage == nil)
        let restarted = ClipboardRepository(fileManager: manager)
        try await waitUntil { restarted.isReady }
        let restartedPage = try await restarted.query()
        precondition(restartedPage.total == 0 && restarted.limits == limits)
        do { _ = try await repository.importBatch(batch, preview: staleImport, expand: false); preconditionFailure("Stale import accepted after clear") }
        catch PasteImportError.stalePreview {}
        print("PASS: clear removes all 1,005 paged/grouped records, assets and legacy backups; groups/settings/original files survive; search and restart stay empty")
        print("PASS: clearing serializes with pending writes and rejects overlapping clear/import/settings changes; old import previews become stale")

        try await Task.sleep(for: .milliseconds(2_600))
        precondition(repository.totalCount == 0 && pasteboard.string(forType: .string) == "Keep current clipboard")
        pasteboard.clearContents()
        pasteboard.setString("Fresh copy after clear", forType: .string)
        try await waitUntil { repository.totalCount == 1 }
        precondition(repository.items[0].textContent == "Fresh copy after clear")
        monitor.stop()
        print("PASS: clear preserves the current named clipboard without recapturing it; a new copy is still recorded")

        try legacyData.write(to: legacy)
        manager.failingFilename = "history.json"
        do { try await repository.clearHistory(); preconditionFailure("Legacy deletion failure ignored") }
        catch ClipboardHistoryClearError.failed {}
        precondition(repository.totalCount == 1 && !repository.isClearingHistory)
        manager.failingFilename = nil
        let freshPreview = try await repository.previewImport(batch)
        _ = try await repository.importBatch(batch, preview: freshPreview, expand: false)
        manager.failingFilename = image.assetFilename
        do { try await repository.clearHistory(); preconditionFailure("Asset deletion failure ignored") }
        catch ClipboardHistoryClearError.filesRemain {}
        precondition(repository.totalCount == 0 && repository.groups == [group])
        precondition(FileManager.default.fileExists(atPath: imageURL.path))
        manager.failingFilename = nil
        try await repository.clearHistory()
        precondition(!FileManager.default.fileExists(atPath: imageURL.path))
        try await repository.clearHistory()
        precondition(repository.groups == [group] && repository.limits == limits)
        print("PASS: migration-source failure preserves current records; asset failure reports partial cleanup, and retry works even with empty history")
    }

    private static func capture(_ text: String) -> ClipboardCapture {
        ClipboardCapture(type: .text, textContent: text, imageData: nil, filePaths: [], sourceAppName: "Fixture", sourceBundleID: "example.fixture", capturedAt: Date())
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        precondition(condition(), "Timed out")
    }
}
