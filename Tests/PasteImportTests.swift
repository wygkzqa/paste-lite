import AppKit
import CryptoKit
import Foundation
import SQLite3
import zlib

private final class ImportFileManager: FileManager, @unchecked Sendable {
    let root: URL
    var failSecondCopy = false
    var beforeFirstCopy: (() -> Void)?
    private var copies = 0
    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        directory == .applicationSupportDirectory ? [root] : super.urls(for: directory, in: domainMask)
    }
    override func copyItem(at source: URL, to destination: URL) throws {
        copies += 1
        if copies == 1 { beforeFirstCopy?() }
        if failSecondCopy && copies == 2 {
            try Data([0]).write(to: destination)
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try super.copyItem(at: source, to: destination)
    }
}

/// Synthetic schema and content. No user database or Paste application resources are used.
final class PasteImportFixture {
    let directory: URL
    private var database: OpaquePointer?
    private var nextID = 0
    let created = Date(timeIntervalSinceReferenceDate: 700_000_000)

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".db_SUPPORT/_EXTERNAL_DATA"), withIntermediateDirectories: true)
        guard sqlite3_open(directory.appendingPathComponent("db.sqlite").path, &database) == SQLITE_OK else { fatalError("fixture database") }
        execute("PRAGMA journal_mode=WAL")
        execute("CREATE TABLE Z_METADATA (Z_PLIST BLOB)")
        execute("CREATE TABLE ZAPPLICATIONENTITY (Z_PK INTEGER PRIMARY KEY, ZNAME TEXT, ZBUNDLEIDENTIFIER TEXT)")
        execute("CREATE TABLE ZITEMENTITY (Z_PK INTEGER PRIMARY KEY, ZCREATEDAT REAL, ZTIMESTAMP REAL, ZSOURCEAPPLICATION INTEGER, ZDATA INTEGER, ZLIST INTEGER, ZTITLE TEXT)")
        execute("CREATE TABLE ZLISTENTITY (Z_PK INTEGER PRIMARY KEY, ZNAME TEXT, ZRAWTYPE INTEGER)")
        execute("CREATE TABLE ZITEMDATAENTITY (Z_PK INTEGER PRIMARY KEY, ZRAWPASTEBOARDITEMS BLOB)")
        execute("INSERT INTO ZAPPLICATIONENTITY VALUES (1, 'Fixture Editor', 'example.fixture')")
        let hashes = [
            "ApplicationEntity": "81a4089f6fcd2002a422c9441d7b769abd405f1275aa09e12bd5fcd38987225d",
            "ItemDataEntity": "8102715aa1cbaae37a8a0049240a67996f9d6b314b5cd34aafd71a167cdb8e57",
            "ItemEntity": "d0cedc9c3f7f56a3b93d6f344357ecf67d912798cddd63d737e1394b168b9e30",
            "ListEntity": "6ae4140d07dc19df96823620e241b0fc8d923918340a0e73cb6e6ae530376708"
        ].mapValues { hex in
            Data(stride(from: 0, to: hex.count, by: 2).map { offset in
                UInt8(hex[hex.index(hex.startIndex, offsetBy: offset)..<hex.index(hex.startIndex, offsetBy: offset + 2)], radix: 16)!
            })
        }
        let metadata = try PropertyListSerialization.data(fromPropertyList: ["NSStoreModelVersionHashes": hashes], format: .binary, options: 0)
        insertBlob("INSERT INTO Z_METADATA VALUES (?)", data: metadata)
    }

    deinit { sqlite3_close(database) }

    func add(_ items: [[String: Data]], external: Bool = false, missing: Bool = false, noTimestamp: Bool = false, groupID: Int64? = nil, title: String? = nil) throws {
        let dictionaries: [[String: Any]] = items.map { ["types": Array($0.keys), "dataByType": $0.mapValues { $0.base64EncodedString() }] }
        let json = try JSONSerialization.data(withJSONObject: dictionaries)
        let compressed = compress(json)
        let data: Data
        if external {
            let name = UUID().uuidString
            if !missing { try compressed.write(to: directory.appendingPathComponent(".db_SUPPORT/_EXTERNAL_DATA/" + name)) }
            data = Data([2]) + Data(name.utf8) + Data([0])
        } else { data = Data([1]) + compressed }
        addEncoded(data, noTimestamp: noTimestamp, groupID: groupID, title: title)
    }

    func addEncoded(_ data: Data, noTimestamp: Bool = false, groupID: Int64? = nil, title: String? = nil) {
        nextID += 1
        insertBlob("INSERT INTO ZITEMDATAENTITY VALUES (\(nextID), ?)", data: data)
        let timestamp = noTimestamp ? "NULL" : String(created.timeIntervalSinceReferenceDate + Double(nextID))
        execute("INSERT INTO ZITEMENTITY (Z_PK, ZCREATEDAT, ZTIMESTAMP, ZSOURCEAPPLICATION, ZDATA, ZLIST) VALUES (\(nextID), \(created.timeIntervalSinceReferenceDate), \(timestamp), 1, \(nextID), \(groupID.map(String.init) ?? "NULL"))")
        if let title {
            insertBlob("UPDATE ZITEMENTITY SET ZTITLE = CAST(? AS TEXT) WHERE Z_PK = \(nextID)", data: Data(title.utf8))
        }
    }

    func addGroup(id: Int64, name: String, type: Int = 2) {
        insertBlob("INSERT INTO ZLISTENTITY VALUES (\(id), CAST(? AS TEXT), \(type))", data: Data(name.utf8))
    }

    func invalidateSchema() { execute("UPDATE Z_METADATA SET Z_PLIST = X'00'") }

    private func execute(_ sql: String) { precondition(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK) }
    private func insertBlob(_ sql: String, data: Data) {
        var query: OpaquePointer?
        precondition(sqlite3_prepare_v2(database, sql, -1, &query, nil) == SQLITE_OK)
        defer { sqlite3_finalize(query) }
        data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(query, 1, bytes.baseAddress, Int32(bytes.count), nil)
            precondition(sqlite3_step(query) == SQLITE_DONE)
        }
    }
    private func compress(_ data: Data) -> Data {
        var stream = z_stream()
        precondition(deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
        defer { deflateEnd(&stream) }
        return data.withUnsafeBytes { bytes in
            stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(bytes.count)
            var buffer = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(bytes.count))))
            var written = 0
            buffer.withUnsafeMutableBytes { output in
                stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(output.count)
                precondition(deflate(&stream, Z_FINISH) == Z_STREAM_END)
                written = output.count - Int(stream.avail_out)
            }
            return Data(buffer.prefix(written))
        }
    }
}

@main
@MainActor
struct PasteImportTests {
    static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLite-import-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try PasteImportFixture(directory: root.appendingPathComponent("source"))
        let originalFile = root.appendingPathComponent("example.txt")
        try Data("Sample file".utf8).write(to: originalFile)
        try fixture.add([["public.utf8-plain-text": Data("existing".utf8)]])
        try fixture.add([["public.utf8-plain-text": Data("duplicate".utf8)]])
        try fixture.add([["public.utf8-plain-text": Data("duplicate".utf8)]])
        try fixture.add([["public.url": Data("https://example.com/".utf8)]])
        try fixture.add([["public.file-url": Data(originalFile.absoluteString.utf8)]])
        try fixture.add([["public.utf16-external-plain-text": "Unicode 文本".data(using: .utf16)!]], noTimestamp: true)
        try fixture.add([["public.rtf": Data("{\\rtf1\\ansi Sample RTF}".utf8)]])
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<16 { for x in 0..<16 { bitmap.setColor(NSColor(deviceRed: 0.2, green: 0.3, blue: 1, alpha: 1), atX: x, y: y) } }
        let png = bitmap.representation(using: .png, properties: [:])!
        try fixture.add([["public.png": png]], external: true)
        try fixture.add([["public.png": png]], external: true, missing: true)
        try fixture.add([["public.file-url": Data("file:///definitely-missing-fixture".utf8)]])
        try fixture.add([["public.html": Data("<script>untrusted()</script>".utf8)]])
        fixture.addEncoded(Data([1, 255, 255]))
        let sourceBefore = try hashes(in: fixture.directory)
        let batch = try await Task.detached { try PasteImportService.scan(directory: fixture.directory) { _, _ in } }.value
        precondition(batch.total == 12 && batch.entries.count == 7 && batch.duplicates == 1)
        precondition(batch.skipped.values.reduce(0, +) == 4)
        let sourceAfter = try hashes(in: fixture.directory)
        precondition(sourceAfter == sourceBefore)
        let imageEntry = batch.entries.first { $0.item.type == .image }!
        precondition(FileManager.default.fileExists(atPath: batch.directory.appendingPathComponent(imageEntry.item.assetFilename!).path))
        precondition(batch.entries.first { $0.item.textContent == "Unicode 文本" }!.item.lastCopiedAt == fixture.created)
        precondition(batch.entries.first { $0.item.textContent == "duplicate" }!.item.lastCopiedAt == fixture.created.addingTimeInterval(3))
        precondition(batch.entries.allSatisfy { $0.item.sourceAppName == "Fixture Editor" && $0.item.sourceBundleID == "example.fixture" && $0.item.createdAt == fixture.created })
        print("PASS: WAL snapshot, compressed inline/external content, text/URL/file/RTF/image mapping, time and source immutability")

        let manager = ImportFileManager(root: root.appendingPathComponent("destination"))
        try FileManager.default.createDirectory(at: manager.root.appendingPathComponent("PasteLite"), withIntermediateDirectories: true)
        try JSONEncoder().encode(ClipboardLimits(itemCount: 2)).write(to: manager.root.appendingPathComponent("PasteLite/history-settings.json"))
        let repository = ClipboardRepository(fileManager: manager)
        repository.record(ClipboardCapture(type: .text, textContent: "existing", imageData: nil, filePaths: [], sourceAppName: "Original", sourceBundleID: "example.original", capturedAt: Date()))
        try await waitUntil { repository.items.count == 1 }
        let original = repository.items[0]
        var preview = try await repository.previewImport(batch)
        precondition(preview.duplicates == 2 && preview.needsExpansion)
        let limited = try await repository.importBatch(batch, preview: preview, expand: false)
        precondition(limited.added == 1 && limited.capacitySkipped == 5 && repository.items.count == 2)
        precondition(repository.items.first { $0.id == original.id } == original)
        preview = try await repository.previewImport(batch)
        let expanded = try await repository.importBatch(batch, preview: preview, expand: true)
        precondition(expanded.added == 5 && repository.items.count == 7)
        precondition(repository.items.first { $0.id == original.id } == original)
        let reloaded = ClipboardRepository(fileManager: manager)
        try await waitUntil { reloaded.items.count == 7 }
        let repeatPreview = try await reloaded.previewImport(batch)
        precondition(repeatPreview.entries.isEmpty && repeatPreview.duplicates == 8)
        print("PASS: partial entry-limited import, expansion persisted across restart, existing metadata preserved, repeated import adds zero")

        let stale = try await repository.previewImport(batch)
        repository.record(ClipboardCapture(type: .text, textContent: "new during scan", imageData: nil, filePaths: [], sourceAppName: "Fixture", sourceBundleID: "example.fixture", capturedAt: Date()))
        try await waitUntil { repository.items.contains { $0.textContent == "new during scan" } }
        do {
            _ = try await repository.importBatch(batch, preview: stale, expand: true)
            preconditionFailure("Stale preview should require confirmation")
        } catch PasteImportError.stalePreview { }
        print("PASS: concurrent history changes require a refreshed preview")

        let failureManager = ImportFileManager(root: root.appendingPathComponent("failure"))
        failureManager.failSecondCopy = true
        let failedRepository = ClipboardRepository(fileManager: failureManager)
        let failurePreview = try await failedRepository.previewImport(batch)
        do {
            _ = try await failedRepository.importBatch(batch, preview: failurePreview, expand: true)
            preconditionFailure("Copy failure should roll back")
        } catch PasteImportError.storage { }
        let empty = try await failedRepository.previewImport(batch)
        precondition(empty.existingHashes.isEmpty)
        for directory in ["Assets", "Thumbnails"] {
            let files = try FileManager.default.contentsOfDirectory(atPath: failureManager.root.appendingPathComponent("PasteLite/" + directory).path)
            precondition(files.isEmpty)
        }
        failureManager.failSecondCopy = false
        _ = try await failedRepository.importBatch(batch, preview: empty, expand: true)
        precondition(failedRepository.items.count == 7)
        print("PASS: failed asset copy rolls back records and new assets; retry succeeds")

        let concurrentManager = ImportFileManager(root: root.appendingPathComponent("concurrent"))
        let concurrentRepository = ClipboardRepository(fileManager: concurrentManager)
        concurrentRepository.record(ClipboardCapture(type: .text, textContent: "existing", imageData: nil, filePaths: [], sourceAppName: "Original", sourceBundleID: "example.original", capturedAt: Date()))
        try await waitUntil { concurrentRepository.items.count == 1 }
        let concurrentlyUsed = concurrentRepository.items[0]
        let concurrentPreview = try await concurrentRepository.previewImport(batch)
        concurrentManager.beforeFirstCopy = {
            let gate = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                Task { @MainActor in
                    precondition(concurrentRepository.isSavingLimits)
                    do {
                        try await concurrentRepository.updateLimits(ClipboardLimits(itemCount: 1))
                        preconditionFailure("Settings must not overwrite limits during final import")
                    } catch PasteImportError.storage { }
                    concurrentRepository.markUsed(concurrentlyUsed)
                    gate.signal()
                }
            }
            precondition(gate.wait(timeout: .now() + 5) == .success)
        }
        _ = try await concurrentRepository.importBatch(batch, preview: concurrentPreview, expand: true)
        _ = try await concurrentRepository.previewImport(batch)
        precondition(concurrentRepository.items.first?.id == concurrentlyUsed.id)
        precondition(concurrentRepository.items.first!.lastCopiedAt > concurrentlyUsed.lastCopiedAt)
        precondition(!concurrentRepository.isSavingLimits)
        print("PASS: final import prevents overlapping settings writes and preserves concurrent record use")

        let largeFixture = try PasteImportFixture(directory: root.appendingPathComponent("cancel-source"))
        for index in 0..<60 { try largeFixture.add([["public.utf8-plain-text": Data("Cancellation sample \(index)".utf8)]]) }
        let temporaryBefore = try FileManager.default.contentsOfDirectory(atPath: root.deletingLastPathComponent().path)
        let cancelled = Task.detached {
            try PasteImportService.scan(directory: largeFixture.directory) { processed, _ in
                if processed == 20 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await cancelled.value; preconditionFailure("Cancellation ignored") }
        catch is CancellationError { }
        let temporaryAfter = try FileManager.default.contentsOfDirectory(atPath: root.deletingLastPathComponent().path)
        let newTemporaryFiles = Set(temporaryAfter).subtracting(temporaryBefore).filter { $0.hasPrefix("PasteLite-import-") }
        precondition(newTemporaryFiles.isEmpty)
        do {
            try PasteImportService.checkDiskSpace(at: root, required: Int64.max)
            preconditionFailure("Insufficient disk space accepted")
        } catch PasteImportError.insufficientSpace { }
        let countLimited = PasteImportPreview(
            entries: [PasteImportEntry(item: imageEntry.item, byteCount: 100), PasteImportEntry(item: original, byteCount: 5)],
            existingHashes: [], existingBytes: 0, limits: ClipboardLimits(itemCount: 1), duplicates: 0
        )
        precondition(countLimited.selectedEntries(expand: false).map(\.item.id) == [imageEntry.item.id])
        precondition(countLimited.needsExpansion && countLimited.selectedEntries(expand: true).count == 2)

        let blockedViewModel = PasteImportViewModel(repository: repository, isPasteRunning: { true })
        blockedViewModel.selectedDirectory = fixture.directory
        blockedViewModel.scan()
        precondition(!blockedViewModel.isScanning && blockedViewModel.message != nil && blockedViewModel.preview == nil)
        let viewModel = PasteImportViewModel(repository: repository, isPasteRunning: { false })
        viewModel.selectedDirectory = fixture.directory
        viewModel.scan()
        try await waitUntil { !viewModel.isScanning }
        precondition(viewModel.preview != nil)
        let stagedDirectory = viewModel.batch!.directory
        viewModel.cancelScan()
        try await waitUntil { !FileManager.default.fileExists(atPath: stagedDirectory.path) }
        precondition(viewModel.preview == nil && viewModel.batch == nil)
        print("PASS: running Paste blocks scanning; closing a completed preview releases staged files")

        try await testGroups(root: root, png: png)
        try await testTitles(root: root, png: png)

        fixture.invalidateSchema()
        do { _ = try PasteImportService.scan(directory: fixture.directory) { _, _ in }; preconditionFailure("Unknown schema accepted") }
        catch PasteImportError.unsupportedStore { }
        print("PASS: mid-scan cancellation cleans temporary files; disk space/entry limits and unsupported schema are enforced")

        let sizeFixture = try PasteImportFixture(directory: root.appendingPathComponent("capture-sizes"))
        let oneMB = 1_024 * 1_024
        let exactText = String(repeating: "中", count: oneMB / 3) + "a"
        try sizeFixture.add([["public.utf8-plain-text": Data(exactText.utf8)]])
        try sizeFixture.add([["public.url": Data(("https://example.com/" + String(repeating: "x", count: oneMB)).utf8)]])
        // An uncompressed TIFF container may be much bigger than its saved PNG.
        let largeBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1_024, pixelsHigh: 1_024, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        memset(largeBitmap.bitmapData!, 255, largeBitmap.bytesPerRow * largeBitmap.pixelsHigh)
        let tiff = largeBitmap.representation(using: .tiff, properties: [:])!
        precondition(tiff.count > 3 * oneMB)
        try sizeFixture.add([["public.tiff": tiff]])
        var oversizePNG = png
        oversizePNG.append(Data(count: oneMB + 1 - png.count))
        try sizeFixture.add([["public.png": oversizePNG]])
        let sizeBatch = try await Task.detached {
            try PasteImportService.scan(directory: sizeFixture.directory, limits: ClipboardLimits(maxTextMB: 1, maxImageMB: 1)) { _, _ in }
        }.value
        precondition(sizeBatch.entries.count == 2 && sizeBatch.skipped.values.reduce(0, +) == 2)
        precondition(sizeBatch.entries.contains { $0.item.textContent == exactText })
        precondition(sizeBatch.entries.contains { $0.item.type == .image })
        let unlimitedBatch = try await Task.detached {
            try PasteImportService.scan(directory: sizeFixture.directory, limits: ClipboardLimits(maxTextMB: 0, maxImageMB: 0)) { _, _ in }
        }.value
        precondition(unlimitedBatch.entries.count == 4 && unlimitedBatch.skipped.isEmpty)
        print("PASS: import uses final UTF-8/PNG limits, accepts a larger TIFF container, skips oversized URL/PNG, and supports unlimited capture")
    }

    private static func testTitles(root: URL, png: Data) async throws {
        let fixture = try PasteImportFixture(directory: root.appendingPathComponent("titles-source"))
        fixture.addGroup(id: 1, name: "Named items")
        let file = root.appendingPathComponent("title-original.txt")
        try Data("Original file".utf8).write(to: file)
        let longTitle = String(repeating: "Imported 标题 ", count: 20).trimmingCharacters(in: .whitespaces)
        try fixture.add([["public.utf8-plain-text": Data("title duplicate".utf8)]], groupID: 1, title: "Older name")
        try fixture.add([["public.utf8-plain-text": Data("title duplicate".utf8)]], title: " Latest '标题' 📋 ")
        try fixture.add([["public.utf8-plain-text": Data("title duplicate".utf8)]], title: " \n ")
        try fixture.add([["public.url": Data("https://example.com/title".utf8)]], title: "网址收藏")
        try fixture.add([["public.png": png]], title: longTitle)
        try fixture.add([["public.file-url": Data(file.absoluteString.utf8)]], title: "文件名称")
        try fixture.add([["public.utf8-plain-text": Data("no title".utf8)]])
        let before = try hashes(in: fixture.directory)
        let batch = try await Task.detached { try PasteImportService.scan(directory: fixture.directory) { _, _ in } }.value
        let after = try hashes(in: fixture.directory)
        precondition(before == after && batch.entries.count == 5 && batch.duplicates == 2)
        precondition(batch.entries.first { $0.item.textContent == "title duplicate" }?.item.customTitle == "Latest '标题' 📋")
        precondition(batch.entries.first { $0.item.textContent == "title duplicate" }?.groupIDs == [1])
        precondition(batch.entries.first { $0.item.type == .image }?.item.customTitle == longTitle)
        precondition(batch.entries.first { $0.item.textContent == "no title" }?.item.customTitle == nil)
        let manager = ImportFileManager(root: root.appendingPathComponent("titles-destination"))
        let repository = ClipboardRepository(fileManager: manager)
        try await waitUntil { repository.isReady }
        let preview = try await repository.previewImport(batch)
        _ = try await repository.importBatch(batch, preview: preview, expand: false)
        for entry in batch.entries {
            let full = try await repository.item(id: entry.item.id)!
            precondition(full.customTitle == entry.item.customTitle && full.displayTitle == entry.item.displayTitle)
        }
        let image = batch.entries.first { $0.item.type == .image }!.item
        let searched = try await repository.query(ClipboardQuery(text: longTitle))
        precondition(searched.items.map(\.id) == [image.id])
        let reopened = ClipboardRepository(fileManager: manager)
        try await waitUntil { reopened.isReady }
        let savedImage = try await reopened.item(id: image.id)
        precondition(savedImage?.customTitle == longTitle)
        print("PASS: Paste ZTITLE imports all content types, preserves long/Unicode titles, chooses newest nonempty duplicate title and leaves source untouched")

        let text = batch.entries.first { $0.item.type == .text && $0.item.customTitle != nil }!.item
        try await repository.renameTitle(id: text.id, title: "Local title wins")
        try await repository.renameTitle(id: image.id, title: "")
        let titleOnly = try await repository.previewImport(batch)
        precondition(titleOnly.entries.isEmpty && !titleOnly.hasGroupChanges && titleOnly.hasChanges)
        precondition(titleOnly.titleUpdates == [image.contentHash: longTitle])
        let viewModel = PasteImportViewModel(repository: repository, isPasteRunning: { false })
        viewModel.selectedDirectory = fixture.directory
        viewModel.scan()
        try await waitUntil { !viewModel.isScanning && viewModel.preview != nil }
        precondition(viewModel.importCount == 0 && viewModel.canImport)
        let result = try await repository.importBatch(batch, preview: titleOnly, expand: false)
        precondition(result.added == 0 && result.titlesUpdated == 1 && result.recordsUpdated == 0)
        let localText = try await repository.item(id: text.id)
        precondition(localText?.customTitle == "Local title wins")
        let repeated = try await repository.previewImport(batch)
        precondition(!repeated.hasChanges && repeated.titleUpdates.isEmpty)

        try await repository.renameTitle(id: image.id, title: "")
        let stale = try await repository.previewImport(batch)
        try await repository.renameTitle(id: image.id, title: "Edited after scan")
        do {
            _ = try await repository.importBatch(batch, preview: stale, expand: false)
            preconditionFailure("Concurrent title edit was overwritten")
        } catch PasteImportError.stalePreview {}
        let concurrent = try await repository.item(id: image.id)
        precondition(concurrent?.customTitle == "Edited after scan")
        print("PASS: title-only reimport fills missing titles, preserves local names, is idempotent and detects edits after scan")

        let failedManager = ImportFileManager(root: root.appendingPathComponent("titles-rollback"))
        let failedRepository = ClipboardRepository(fileManager: failedManager)
        failedRepository.record(ClipboardCapture(type: .text, textContent: "title duplicate", imageData: nil,
            filePaths: [], sourceAppName: "Fixture", sourceBundleID: "example.fixture", capturedAt: Date()))
        try await waitUntil { failedRepository.totalCount == 1 }
        let existingID = failedRepository.items[0].id
        let failedPreview = try await failedRepository.previewImport(batch)
        precondition(failedPreview.titleUpdates.count == 1)
        failedManager.failSecondCopy = true
        do {
            _ = try await failedRepository.importBatch(batch, preview: failedPreview, expand: false)
            preconditionFailure("Import failure was ignored")
        } catch PasteImportError.storage {}
        let unchanged = try await failedRepository.item(id: existingID)
        precondition(unchanged?.customTitle == nil && failedRepository.totalCount == 1)
        print("PASS: failed import rolls back title backfills with groups, records and assets")
    }

    private static func testGroups(root: URL, png: Data) async throws {
        let fixture = try PasteImportFixture(directory: root.appendingPathComponent("groups-source"))
        fixture.addGroup(id: 1, name: "History", type: 1)
        fixture.addGroup(id: 2, name: "Unknown", type: 0)
        fixture.addGroup(id: 10, name: " Work ")
        fixture.addGroup(id: 11, name: "个人 ' snippets")
        fixture.addGroup(id: 12, name: "Empty")
        fixture.addGroup(id: 13, name: "work")
        let longName = String(repeating: "Long group ", count: 6).trimmingCharacters(in: .whitespaces)
        fixture.addGroup(id: 14, name: longName)
        try fixture.add([["public.utf8-plain-text": Data("existing grouped".utf8)]], groupID: 10)
        try fixture.add([["public.utf8-plain-text": Data("existing grouped".utf8)]], groupID: 11)
        try fixture.add([["public.utf8-plain-text": Data("new grouped".utf8)]], groupID: 10)
        try fixture.add([["public.utf8-plain-text": Data("new grouped".utf8)]], groupID: 11)
        try fixture.add([["public.utf8-plain-text": Data("new grouped".utf8)]], groupID: 13)
        try fixture.add([["public.utf8-plain-text": Data("history only".utf8)]], groupID: 1)
        try fixture.add([["public.png": png]], groupID: 10)
        try fixture.add([["public.png": png]], external: true, missing: true, groupID: 11)
        let before = try hashes(in: fixture.directory)
        let batch = try await Task.detached { try PasteImportService.scan(directory: fixture.directory) { _, _ in } }.value
        let after = try hashes(in: fixture.directory)
        precondition(after == before)
        precondition(batch.groups.count == 5 && batch.entries.count == 4 && batch.duplicates == 3)
        precondition(batch.entries.first { $0.item.textContent == "new grouped" }?.groupIDs == [10, 11, 13])
        precondition(batch.entries.first { $0.item.textContent == "history only" }?.groupIDs.isEmpty == true)
        precondition(batch.skipped.values.reduce(0, +) == 1)
        print("PASS: verified Pinboard schema, history exclusion, empty groups, Unicode names, multi-board deduplication, source unchanged")

        let manager = ImportFileManager(root: root.appendingPathComponent("groups-destination"))
        let repository = ClipboardRepository(fileManager: manager)
        repository.record(ClipboardCapture(type: .text, textContent: "existing grouped", imageData: nil, filePaths: [], sourceAppName: "Original", sourceBundleID: "example.original", capturedAt: Date()))
        try await waitUntil { repository.items.count == 1 }
        let work = try await repository.saveGroup(name: "WORK")
        let local = try await repository.saveGroup(name: "Local")
        let originalID = repository.items[0].id
        try await repository.setGroups([local.id], for: originalID)
        let original = try await repository.item(id: originalID)!
        try await repository.updateLimits(ClipboardLimits(itemCount: 1))
        var preview = try await repository.previewImport(batch)
        precondition(preview.groupsToCreate.count == 3 && preview.groupUpdates.count == 1)
        precondition(preview.selectedEntries(expand: false).isEmpty && preview.hasGroupChanges)
        let limited = try await repository.importBatch(batch, preview: preview, expand: false)
        precondition(limited.added == 0 && limited.groupsAdded == 3 && limited.recordsUpdated == 1 && limited.capacitySkipped == 3)
        try await waitUntil { repository.groups.count == 5 }
        let personal = repository.groups.first { $0.name == "个人 ' snippets" }!
        let imported = try await repository.item(id: originalID)!
        var expected = original
        expected.groupIDs = [local.id, work.id, personal.id].sorted { $0.uuidString < $1.uuidString }
        precondition(imported == expected)
        precondition(repository.groups.contains { $0.name == longName })
        preview = try await repository.previewImport(batch)
        let expanded = try await repository.importBatch(batch, preview: preview, expand: true)
        precondition(expanded.added == 3 && expanded.groupsAdded == 0 && expanded.recordsUpdated == 0)
        let reloaded = ClipboardRepository(fileManager: manager)
        try await waitUntil { reloaded.items.count == 4 && reloaded.groups.count == 5 }
        precondition(Set(reloaded.items.first { $0.textContent == "new grouped" }!.groupIDs!) == [work.id, personal.id])
        precondition(reloaded.items.first { $0.textContent == "history only" }?.groupIDs == nil)
        let repeated = try await reloaded.previewImport(batch)
        precondition(repeated.entries.isEmpty && !repeated.hasGroupChanges)
        print("PASS: full-capacity group-only import, same-name merge, local memberships and metadata preserved, restart and repeat import")

        let stale = try await repository.previewImport(batch)
        try await repository.setGroups([local.id], for: originalID)
        do {
            _ = try await repository.importBatch(batch, preview: stale, expand: true)
            preconditionFailure("Changed memberships must refresh the preview")
        } catch PasteImportError.stalePreview { }
        let renamedPreview = try await repository.previewImport(batch)
        _ = try await repository.saveGroup(id: personal.id, name: "Personal renamed")
        do {
            _ = try await repository.importBatch(batch, preview: renamedPreview, expand: true)
            preconditionFailure("Changed groups must refresh the preview")
        } catch PasteImportError.stalePreview { }
        _ = try await repository.saveGroup(id: personal.id, name: "个人 ' snippets")
        let viewModel = PasteImportViewModel(repository: repository, isPasteRunning: { false })
        viewModel.selectedDirectory = fixture.directory
        viewModel.scan()
        try await waitUntil { !viewModel.isScanning }
        precondition(viewModel.importCount == 0 && viewModel.canImport && viewModel.preview?.groupUpdates.count == 1)
        viewModel.importRecords()
        try await waitUntil { !viewModel.isSaving }
        precondition(viewModel.result?.added == 0 && viewModel.result?.recordsUpdated == 1)
        print("PASS: group edits invalidate preview; the UI can restore memberships when all content already exists")

        let failureManager = ImportFileManager(root: root.appendingPathComponent("groups-rollback"))
        failureManager.failSecondCopy = true
        let failedRepository = ClipboardRepository(fileManager: failureManager)
        failedRepository.record(ClipboardCapture(type: .text, textContent: "existing grouped", imageData: nil, filePaths: [], sourceAppName: "Original", sourceBundleID: "example.original", capturedAt: Date()))
        try await waitUntil { failedRepository.items.count == 1 }
        let retained = try await failedRepository.saveGroup(name: "Retained")
        let retainedID = failedRepository.items[0].id
        try await failedRepository.setGroups([retained.id], for: retainedID)
        let failurePreview = try await failedRepository.previewImport(batch)
        do {
            _ = try await failedRepository.importBatch(batch, preview: failurePreview, expand: true)
            preconditionFailure("Asset failure must roll back groups and memberships")
        } catch PasteImportError.storage { }
        let afterFailure = try await failedRepository.previewImport(batch)
        precondition(afterFailure.existingGroups == [retained])
        precondition(afterFailure.existingMemberships.values.first == [retained.id])
        precondition(afterFailure.existingHashes.count == 1 && afterFailure.groupsToCreate.count == 4)
        failureManager.failSecondCopy = false
        let retried = try await failedRepository.importBatch(batch, preview: afterFailure, expand: true)
        precondition(retried.groupsAdded == 4 && retried.recordsUpdated == 1 && retried.added == 3)
        print("PASS: asset-copy failure rolls back new groups and duplicate memberships together; retry succeeds")

        let emptyFixture = try PasteImportFixture(directory: root.appendingPathComponent("empty-pinboard"))
        emptyFixture.addGroup(id: 1, name: "Only empty board")
        let emptyViewModel = PasteImportViewModel(repository: repository, isPasteRunning: { false })
        emptyViewModel.selectedDirectory = emptyFixture.directory
        emptyViewModel.scan()
        try await waitUntil { !emptyViewModel.isScanning }
        precondition(emptyViewModel.importCount == 0 && emptyViewModel.canImport)
        emptyViewModel.importRecords()
        try await waitUntil { !emptyViewModel.isSaving }
        precondition(emptyViewModel.result?.groupsAdded == 1 && emptyViewModel.result?.added == 0)
        print("PASS: an entirely empty Pinboard can be imported through the UI")
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        preconditionFailure("Timed out")
    }

    private static func hashes(in directory: URL) throws -> [String: Data] {
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])!
        var result: [String: Data] = [:]
        for case let file as URL in files where (try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true) {
            // Shared-memory read marks may change when SQLite readers connect; persisted DB/WAL and assets must not.
            if file.lastPathComponent.hasSuffix("-shm") { continue }
            result[file.lastPathComponent] = Data(SHA256.hash(data: try Data(contentsOf: file)))
        }
        return result
    }
}
