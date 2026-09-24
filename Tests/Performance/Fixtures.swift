import AppKit

final class PerformanceFileManager: FileManager, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        directory == .applicationSupportDirectory ? [root] : super.urls(for: directory, in: domainMask)
    }
}

enum PerformanceFixtures {
    static func makeBatch(count: Int, root: URL) throws -> PasteImportBatch {
        let directory = root.appendingPathComponent("batch-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 128, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        memset(bitmap.bitmapData!, 128, bitmap.bytesPerRow * bitmap.pixelsHigh)
        let png = bitmap.representation(using: .png, properties: [:])!
        // Unique image paths exercise cache misses; data is synthetic and deliberately small.
        for index in 0..<min(count, 512) { try png.write(to: directory.appendingPathComponent("image-\(index).png")) }
        let file = root.appendingPathComponent("fixture.txt")
        try Data("Synthetic file".utf8).write(to: file)
        let now = Date()
        let paragraph = String(repeating: "Synthetic text 中文 performance sample.\n", count: 240)
        let longLine = String(repeating: "Long line 中文 ", count: 800)
        var entries: [PasteImportEntry] = []
        for index in 0..<count {
            let kind = index % 10
            let type: ClipboardContentType = kind < 6 ? .text : kind < 8 ? .image : kind == 8 ? .url : .file
            let text: String? = type == .text ? "Record \(index) " + (kind == 0 ? paragraph : kind == 1 ? longLine : "Short sample") : type == .url ? "https://example.com/fixture/\(index)" : nil
            let image = type == .image ? "image-\(index % min(count, 512)).png" : nil
            let time = now.addingTimeInterval(-Double(index) * 180)
            let item = ClipboardItem(id: UUID(), type: type, textContent: text, assetFilename: image, thumbnailFilename: image, filePaths: type == .file ? [index % 20 == 9 ? file.path : root.appendingPathComponent("missing.txt").path] : [], sourceAppName: "Fixture App \(index % 20)", sourceBundleID: "example.fixture.\(index % 20)", contentHash: "fixture-\(index)", createdAt: time, lastCopiedAt: time)
            entries.append(PasteImportEntry(item: item, byteCount: Int64(text?.utf8.count ?? png.count)))
        }
        return PasteImportBatch(directory: directory, entries: entries, total: count, duplicates: 0, skipped: [:])
    }
}
