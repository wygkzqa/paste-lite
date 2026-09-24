import AppKit
import Foundation

@main
@MainActor
struct HistoryLimitsTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLite-limits-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyRoot = root.appendingPathComponent("legacy")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ".build/tests/legacy-history-fixture")
        process.arguments = [legacyRoot.path]
        try process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        let legacy = ClipboardRepository(fileManager: PerformanceFileManager(root: legacyRoot))
        try await waitUntil { legacy.totalCount == 1_205 || legacy.errorMessage != nil }
        precondition(legacy.errorMessage == nil && legacy.limits == .default)
        precondition(legacy.items.count == ClipboardRepository.pageSize)
        let found = try await legacy.query(ClipboardQuery(text: "legacy-tail-needle"))
        precondition(found.total == 1 && found.items[0].textContent!.count <= 200)
        let detail = try await legacy.item(id: found.items[0].id)
        precondition(detail!.textContent!.hasSuffix("legacy-tail-needle"))
        precondition(detail!.textContent!.count > 4_000)
        print("PASS: old SwiftData store migrates, all 1,205 entries survive obsolete one-entry/one-byte limits, summaries preserve full details")

        let model = ClipboardViewModel(repository: legacy)
        try await waitUntil { model.resultCount == 1_205 && !model.isLoading }
        let firstIDs = Set(model.filteredItems.map(\.id))
        model.selectedID = model.filteredItems.last!.id
        model.moveSelection(by: 1)
        try await waitUntil { model.filteredItems.count == 400 && !model.isLoading }
        precondition(model.selectedID == model.filteredItems[200].id)
        precondition(Set(model.filteredItems.map(\.id)).count == 400)
        precondition(firstIDs.isSubset(of: Set(model.filteredItems.map(\.id))))
        let firstMatches = try await legacy.query(ClipboardQuery(text: "Legacy record"))
        let nextMatches = try await legacy.query(ClipboardQuery(text: "Legacy record"), offset: 200)
        precondition(firstMatches.total == 1_205 && nextMatches.total == 1_205)
        precondition(nextMatches.items.count == 200)
        precondition(Set(firstMatches.items.map(\.id)).isDisjoint(with: Set(nextMatches.items.map(\.id))))
        var pasted: ClipboardItem?
        model.onPaste = { pasted = $0 }
        model.query = "legacy-tail-needle"
        try await waitUntil { model.resultCount == 1 && !model.isLoading }
        model.pasteSelected()
        try await waitUntil { pasted != nil }
        precondition(pasted?.textContent == detail?.textContent)
        model.query = "no-match"
        model.loadNextPage()
        model.query = "Legacy record 0 "
        try await waitUntil { model.resultCount == 1 && model.filteredItems.first?.contentHash == "legacy-0" }
        print("PASS: keyboard crosses page boundary, pages have no duplicate IDs, full-history search and paste return full content")

        let oneMB = 1_024 * 1_024
        var limits = ClipboardLimits(maxTextMB: 1, maxImageMB: 1)
        let exact = String(repeating: "中", count: oneMB / 3) + "a"
        precondition(exact.utf8.count == oneMB)
        precondition(PreparedCapture.prepare(capture(exact), limits: limits) != nil)
        precondition(PreparedCapture.prepare(capture(exact + "a"), limits: limits) == nil)
        precondition(PreparedCapture.prepare(capture(exact + "a", type: .url), limits: limits) == nil)
        limits.maxTextMB = 0
        precondition(PreparedCapture.prepare(capture(exact + "a"), limits: limits) != nil)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        memset(bitmap.bitmapData!, 128, bitmap.bytesPerRow * bitmap.pixelsHigh)
        var png = bitmap.representation(using: .png, properties: [:])!
        png.append(Data(count: oneMB - png.count))
        var imageCapture = ClipboardCapture(type: .image, textContent: nil, imageData: png, filePaths: [],
            sourceAppName: "Fixture", sourceBundleID: "test.fixture", capturedAt: Date())
        precondition(PreparedCapture.prepare(imageCapture, limits: limits) != nil)
        png.append(0)
        imageCapture = ClipboardCapture(type: .image, textContent: nil, imageData: png, filePaths: [],
            sourceAppName: "Fixture", sourceBundleID: "test.fixture", capturedAt: Date())
        precondition(PreparedCapture.prepare(imageCapture, limits: limits) == nil)
        limits.maxImageMB = 0
        precondition(PreparedCapture.prepare(imageCapture, limits: limits) != nil)
        precondition(!ClipboardLimits(itemCount: -1).isValid)
        print("PASS: UTF-8 and URL limits, exact text/PNG boundaries, over-limit rejection and zero/unlimited semantics")

        let manager = PerformanceFileManager(root: root.appendingPathComponent("cleanup"))
        let repository = ClipboardRepository(fileManager: manager)
        try await waitUntil { repository.isReady }
        let now = Date()
        for (text, days) in [("old", 5.0), ("boundary", 2.0), ("middle", 1.0), ("new", 0.0)] {
            repository.record(capture(text, date: now.addingTimeInterval(-days * 86_400)))
        }
        try await waitUntil { repository.totalCount == 4 }
        let old = repository.items.first { $0.textContent == "old" }!
        repository.markUsed(old)
        try await waitUntil { repository.items.first?.id == old.id }
        let before = repository.items.count
        try await repository.updateLimits(ClipboardLimits(itemCount: 2, retentionDays: 2))
        precondition(repository.totalCount == before)
        await repository.checkCleanup(now: now.addingTimeInterval(10 * 3_600))
        precondition(repository.totalCount == 4)
        let removed = try await repository.cleanHistory(now: now)
        precondition(removed == 2 && repository.totalCount == 2)
        precondition(Set(repository.items.compactMap(\.textContent)) == ["middle", "new"])
        try await repository.updateLimits(ClipboardLimits(itemCount: 1, cleanupIntervalHours: 1))
        await repository.checkCleanup(now: now.addingTimeInterval(10))
        precondition(repository.totalCount == 2)
        await repository.checkCleanup(now: now.addingTimeInterval(3_601))
        precondition(repository.totalCount == 1 && repository.items[0].textContent == "new")
        let reloaded = ClipboardRepository(fileManager: manager)
        try await waitUntil { reloaded.totalCount == 1 }
        precondition(reloaded.limits.itemCount == 1 && reloaded.limits.cleanupIntervalHours == 1)
        print("PASS: no immediate cleanup on edit, zero interval disables timer, creation date wins over last use, combined limits and persistence")

        let batch = try PerformanceFixtures.makeBatch(count: 3, root: root)
        try await repository.updateLimits(.default)
        let preview = try await repository.previewImport(batch)
        precondition(!preview.needsExpansion && preview.selectedEntries(expand: false).count == 3)
        try await repository.updateLimits(ClipboardLimits(maxTextMB: 1))
        do {
            _ = try await repository.importBatch(batch, preview: preview, expand: false)
            preconditionFailure("Changed capture settings must invalidate the scan")
        } catch PasteImportError.settingsChanged { }
        precondition(repository.totalCount == 1)
        print("PASS: unlimited import has no expansion and settings changes invalidate previously scanned data")

        let startupManager = PerformanceFileManager(root: root.appendingPathComponent("startup"))
        let startupSource = ClipboardRepository(fileManager: startupManager)
        try await waitUntil { startupSource.isReady }
        startupSource.record(capture("expired", date: now.addingTimeInterval(-2 * 86_400 - 1)))
        startupSource.record(capture("exact boundary", date: now.addingTimeInterval(-2 * 86_400)))
        try await waitUntil { startupSource.totalCount == 2 }
        try await startupSource.updateLimits(ClipboardLimits(retentionDays: 2))
        let expiredCount = try await startupSource.cleanHistory(now: now)
        precondition(expiredCount == 1 && startupSource.items[0].textContent == "exact boundary")
        try await startupSource.updateLimits(ClipboardLimits(retentionDays: 1))
        precondition(startupSource.totalCount == 1)
        let startupResult = ClipboardRepository(fileManager: startupManager)
        try await waitUntil { startupResult.isReady }
        let remaining = try await startupResult.query()
        precondition(remaining.total == 0)
        print("PASS: retention includes its exact boundary, and startup cleanup applies saved rules even with the timer disabled")

        let failureManager = PerformanceFileManager(root: root.appendingPathComponent("settings-failure"))
        let failureRepository = ClipboardRepository(fileManager: failureManager)
        try await waitUntil { failureRepository.isReady }
        try FileManager.default.createDirectory(at: failureManager.root.appendingPathComponent("PasteLite/history-settings.json"), withIntermediateDirectories: true)
        do {
            try await failureRepository.updateLimits(ClipboardLimits(itemCount: 1))
            preconditionFailure("A failed setting write must report failure")
        } catch { }
        precondition(failureRepository.limits == .default && !failureRepository.isSavingLimits)
        print("PASS: failed settings persistence retains the previous effective limits")
    }

    private static func capture(_ text: String, type: ClipboardContentType = .text, date: Date = Date()) -> ClipboardCapture {
        ClipboardCapture(type: type, textContent: text, imageData: nil, filePaths: [], sourceAppName: "Fixture",
                         sourceBundleID: "test.fixture", capturedAt: date)
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        precondition(condition(), "Timed out")
    }
}
