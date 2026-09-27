import AppKit
import ImageIO

@main
@MainActor
struct SourceAppIconTests {
    static func main() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLite-icon-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let red = image(.red), blue = image(.blue)
        let manager = PerformanceFileManager(root: root)
        let repository = ClipboardRepository(fileManager: manager, installedSourceIcon: { _ in nil })
        try await ready(repository)
        let first = try await record(repository, "First", source: "example.one", icon: red)
        let second = try await record(repository, "Second", source: "example.one", icon: blue)
        let other = try await record(repository, "Other", source: "example.two", icon: blue)
        let icons = root.appendingPathComponent(AppVariant.dataDirectoryName).appendingPathComponent("SourceAppIcons")
        let firstURL = await repository.sourceIconURL(for: first.sourceBundleID)!
        let otherURL = await repository.sourceIconURL(for: other.sourceBundleID)!
        let saved = try Data(contentsOf: firstURL)
        precondition(saved == SourceAppIcon.pngData(from: red))
        precondition(firstURL != otherURL && files(in: icons).count == 2)
        let source = CGImageSourceCreateWithData(saved as CFData, nil)!
        let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        precondition(decoded.width == 64 && decoded.height == 64 && decoded.alphaInfo != .none)
        let loaded = await ClipboardImageLoader.load(from: firstURL, maxPixelSize: 64)
        precondition(loaded != nil)
        print("PASS: captures persist 64px icons, share a file by bundle ID, preserve the first icon and use the image loader")

        let reopened = ClipboardRepository(fileManager: manager, installedSourceIcon: { _ in
            preconditionFailure("A persisted icon must not require the original application")
        })
        try await ready(reopened)
        let reopenedURL = await reopened.sourceIconURL(for: first.sourceBundleID)
        precondition(reopenedURL == firstURL)
        print("PASS: reopening reads persisted icons without an installed/running source application")

        try await repository.deleteItems([first.id])
        precondition(FileManager.default.fileExists(atPath: firstURL.path))
        try await repository.deleteItems([second.id])
        precondition(!FileManager.default.fileExists(atPath: firstURL.path))
        precondition(FileManager.default.fileExists(atPath: otherURL.path))
        let stale = await repository.sourceIconURL(for: "example.one")
        precondition(stale == nil)
        print("PASS: deletion retains shared icons until the last reference and rejects requests from deleted rows")

        let moved = try await record(repository, "Other", source: "example.three", icon: red)
        precondition(moved.id == other.id && moved.sourceBundleID == "example.three")
        let movedURL = await repository.sourceIconURL(for: moved.sourceBundleID)!
        precondition(movedURL != otherURL)
        let afterMove = ClipboardRepository(fileManager: manager, installedSourceIcon: { _ in nil })
        try await ready(afterMove)
        precondition(!FileManager.default.fileExists(atPath: otherURL.path))
        precondition(FileManager.default.fileExists(atPath: movedURL.path))
        print("PASS: deduplication switches the icon with the source; startup removes orphaned icons")

        try await backfillAndRepair(root: root.appendingPathComponent("backfill"), image: red)
        try await failedWrites(root: root.appendingPathComponent("failed-write"), image: red)
        try await clearingDuringBackfill(root: root.appendingPathComponent("clear-race"), image: red)

        let old = try await record(repository, "Expired", source: "example.expired", icon: red,
                                   date: Date().addingTimeInterval(-3 * 86_400))
        let expiredURL = await repository.sourceIconURL(for: old.sourceBundleID)!
        try await repository.updateLimits(ClipboardLimits(retentionDays: 1))
        _ = try await repository.cleanHistory()
        precondition(!FileManager.default.fileExists(atPath: expiredURL.path))
        precondition(FileManager.default.fileExists(atPath: movedURL.path))
        let group = try await repository.saveGroup(name: "Keep group")
        try await repository.clearHistory()
        precondition(files(in: icons).isEmpty && repository.groups.contains(where: { $0.id == group.id }))
        precondition(repository.limits.retentionDays == 1)
        print("PASS: retention and clear remove icon files while preserving groups and settings")
    }

    private static func backfillAndRepair(root: URL, image: CGImage) async throws {
        let manager = PerformanceFileManager(root: root)
        let provider = IconProvider(image: image)
        let repository = ClipboardRepository(fileManager: manager, installedSourceIcon: provider.load)
        try await ready(repository)
        let item = try await record(repository, "Old or imported record", source: "example.old")
        async let first = repository.sourceIconURL(for: item.sourceBundleID)
        async let second = repository.sourceIconURL(for: item.sourceBundleID)
        let urls = await [first, second]
        precondition(urls[0] != nil && urls[0] == urls[1] && provider.count == 1)
        let url = urls[0]!
        try Data("Broken synthetic PNG".utf8).write(to: url)
        let reopened = ClipboardRepository(fileManager: manager, installedSourceIcon: provider.load)
        try await ready(reopened)
        let repaired = await reopened.sourceIconURL(for: item.sourceBundleID)
        precondition(repaired == url && provider.count == 2)
        precondition(CGImageSourceCreateWithURL(url as CFURL, nil) != nil)

        let unknown = try await record(repository, "Missing application", source: "example.missing")
        provider.setImage(nil)
        let missing = await repository.sourceIconURL(for: unknown.sourceBundleID)
        let stillMissing = await repository.sourceIconURL(for: unknown.sourceBundleID)
        let empty = await repository.sourceIconURL(for: "")
        precondition(missing == nil && stillMissing == nil && empty == nil && provider.count == 3)
        _ = try await record(repository, "Missing application", source: unknown.sourceBundleID, icon: image)
        let captured = await repository.sourceIconURL(for: unknown.sourceBundleID)
        precondition(captured != nil && provider.count == 3)
        print("PASS: old/imported sources backfill once, broken PNGs repair, absent sources cache misses and a new capture recovers")
    }

    private static func failedWrites(root: URL, image: CGImage) async throws {
        let repository = ClipboardRepository(fileManager: PerformanceFileManager(root: root), installedSourceIcon: { _ in nil })
        try await ready(repository)
        let icons = root.appendingPathComponent(AppVariant.dataDirectoryName).appendingPathComponent("SourceAppIcons")
        try Data("Block directory creation".utf8).write(to: icons)
        let item = try await record(repository, "Keep text even when icon fails", source: "example.write-failure", icon: image)
        let failed = await repository.sourceIconURL(for: item.sourceBundleID)
        precondition(failed == nil && repository.errorMessage == nil)
        try FileManager.default.removeItem(at: icons)
        _ = try await record(repository, "Keep text even when icon fails", source: item.sourceBundleID, icon: image)
        let recovered = await repository.sourceIconURL(for: item.sourceBundleID)
        precondition(recovered != nil)
        print("PASS: icon write failure does not lose clipboard content and a later capture retries")
    }

    private static func clearingDuringBackfill(root: URL, image: CGImage) async throws {
        let started = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let repository = ClipboardRepository(fileManager: PerformanceFileManager(root: root), installedSourceIcon: { _ in
            started.signal()
            precondition(resume.wait(timeout: .now() + 10) == .success)
            return image
        })
        try await ready(repository)
        let item = try await record(repository, "Clear during icon lookup", source: "example.race")
        let lookup = Task { await repository.sourceIconURL(for: item.sourceBundleID) }
        let hasStarted = { started.wait(timeout: .now()) == .success }
        var lookupStarted = false
        for _ in 0..<500 {
            if hasStarted() { lookupStarted = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(lookupStarted)
        let clear = Task { try await repository.clearHistory() }
        for _ in 0..<500 where !repository.isClearingHistory { try await Task.sleep(for: .milliseconds(10)) }
        precondition(repository.isClearingHistory)
        resume.signal()
        _ = await lookup.value
        try await clear.value
        let stale = await repository.sourceIconURL(for: item.sourceBundleID)
        let icons = root.appendingPathComponent(AppVariant.dataDirectoryName).appendingPathComponent("SourceAppIcons")
        precondition(stale == nil && files(in: icons).isEmpty && repository.totalCount == 0)
        print("PASS: clear drains in-flight backfill and stale row requests cannot recreate icons")
    }

    private static func ready(_ repository: ClipboardRepository) async throws {
        for _ in 0..<500 where !repository.isReady { try await Task.sleep(for: .milliseconds(10)) }
        precondition(repository.isReady)
    }

    private static func record(_ repository: ClipboardRepository, _ text: String, source: String,
                               icon: CGImage? = nil, date: Date = Date()) async throws -> ClipboardItem {
        repository.record(ClipboardCapture(type: .text, textContent: text, imageData: nil, filePaths: [],
                                          sourceAppName: "Same display name", sourceBundleID: source, capturedAt: date, sourceIcon: icon))
        let page = try await repository.query(ClipboardQuery(text: text))
        precondition(page.items.count == 1 && page.items[0].sourceBundleID == source)
        return page.items[0]
    }

    private static func image(_ color: NSColor) -> CGImage {
        let context = CGContext(data: nil, width: 128, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 64))
        return context.makeImage()!
    }

    private static func files(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }
}

private final class IconProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var image: CGImage?
    private var calls = 0

    init(image: CGImage?) { self.image = image }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func setImage(_ image: CGImage?) { lock.lock(); self.image = image; lock.unlock() }
    func load(_ bundleID: String) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return image
    }
}
