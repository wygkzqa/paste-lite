import AppKit
import CryptoKit
import Foundation
import ImageIO
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
        execute("CREATE TABLE ZAPPLICATIONENTITY (Z_PK INTEGER PRIMARY KEY, ZNAME TEXT, ZBUNDLEIDENTIFIER TEXT, ZRAWICON BLOB)")
        execute("CREATE TABLE ZITEMENTITY (Z_PK INTEGER PRIMARY KEY, ZCREATEDAT REAL, ZTIMESTAMP REAL, ZSOURCEAPPLICATION INTEGER, ZDATA INTEGER, ZLIST INTEGER, ZTITLE TEXT)")
        execute("CREATE TABLE ZLISTENTITY (Z_PK INTEGER PRIMARY KEY, ZNAME TEXT, ZRAWTYPE INTEGER, ZRAWATTRIBUTES BLOB)")
        execute("CREATE TABLE ZITEMDATAENTITY (Z_PK INTEGER PRIMARY KEY, ZRAWPASTEBOARDITEMS BLOB)")
        execute("INSERT INTO ZAPPLICATIONENTITY (Z_PK, ZNAME, ZBUNDLEIDENTIFIER) VALUES (1, 'Fixture Editor', 'example.fixture')")
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

    func add(_ items: [[String: Data]], external: Bool = false, missing: Bool = false, noTimestamp: Bool = false, groupID: Int64? = nil, title: String? = nil, sourceID: Int? = 1) throws {
        let dictionaries: [[String: Any]] = items.map { ["types": Array($0.keys), "dataByType": $0.mapValues { $0.base64EncodedString() }] }
        let json = try JSONSerialization.data(withJSONObject: dictionaries)
        let compressed = compress(json)
        let data: Data
        if external {
            let name = UUID().uuidString
            if !missing { try compressed.write(to: directory.appendingPathComponent(".db_SUPPORT/_EXTERNAL_DATA/" + name)) }
            data = Data([2]) + Data(name.utf8) + Data([0])
        } else { data = Data([1]) + compressed }
        addEncoded(data, noTimestamp: noTimestamp, groupID: groupID, title: title, sourceID: sourceID)
    }

    func addEncoded(_ data: Data, noTimestamp: Bool = false, groupID: Int64? = nil, title: String? = nil, sourceID: Int? = 1) {
        nextID += 1
        insertBlob("INSERT INTO ZITEMDATAENTITY VALUES (\(nextID), ?)", data: data)
        let timestamp = noTimestamp ? "NULL" : String(created.timeIntervalSinceReferenceDate + Double(nextID))
        execute("INSERT INTO ZITEMENTITY (Z_PK, ZCREATEDAT, ZTIMESTAMP, ZSOURCEAPPLICATION, ZDATA, ZLIST) VALUES (\(nextID), \(created.timeIntervalSinceReferenceDate), \(timestamp), \(sourceID.map(String.init) ?? "NULL"), \(nextID), \(groupID.map(String.init) ?? "NULL"))")
        if let title {
            insertBlob("UPDATE ZITEMENTITY SET ZTITLE = CAST(? AS TEXT) WHERE Z_PK = \(nextID)", data: Data(title.utf8))
        }
    }

    func addApplication(id: Int, bundleID: String, icon: Data) {
        insertBlob("INSERT INTO ZAPPLICATIONENTITY (Z_PK, ZNAME, ZBUNDLEIDENTIFIER) VALUES (\(id), 'Fixture App', CAST(? AS TEXT))", data: Data(bundleID.utf8))
        setIcon(icon, applicationID: id)
    }

    func setIcon(_ data: Data, applicationID: Int = 1) {
        insertBlob("UPDATE ZAPPLICATIONENTITY SET ZRAWICON = ? WHERE Z_PK = \(applicationID)", data: data)
    }

    func addGroup(id: Int64, name: String, type: Int = 2, attributes: Data? = nil) {
        insertBlob("INSERT INTO ZLISTENTITY (Z_PK, ZNAME, ZRAWTYPE) VALUES (\(id), CAST(? AS TEXT), \(type))", data: Data(name.utf8))
        if let attributes {
            insertBlob("UPDATE ZLISTENTITY SET ZRAWATTRIBUTES = ? WHERE Z_PK = \(id)", data: attributes)
        }
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
        try await testGroupColors(root: root, png: png)
        try await testSourceIcons(root: root, png: png)
        try await testWindowFocus(root: root, repository: repository, source: fixture.directory)
        try await testTitles(root: root, png: png)
        try await testTextURLs(root: root)

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

    private static func testTextURLs(root: URL) async throws {
        let fixture = try PasteImportFixture(directory: root.appendingPathComponent("text-urls"))
        let link = "http://clipboard.account.qa.internal.example.com"
        let mixed = "Visit \(link) for details"
        fixture.addGroup(id: 1, name: "Saved links")
        try fixture.add([["public.url": Data(link.utf8)]])
        try fixture.add([["public.utf8-plain-text": Data(link.utf8)]], groupID: 1, title: "Saved link")
        try fixture.add([["public.utf8-plain-text": Data(mixed.utf8)]])
        let batch = try await Task.detached { try PasteImportService.scan(directory: fixture.directory) { _, _ in } }.value
        precondition(batch.entries.count == 2 && batch.duplicates == 1)
        let url = batch.entries.first { $0.item.type == .url }!
        precondition(url.item.textContent == link && url.item.customTitle == "Saved link" && url.groupIDs == [1])
        precondition(batch.entries.first { $0.item.type == .text }?.item.textContent == mixed)
        let repository = ClipboardRepository(fileManager: ImportFileManager(root: root.appendingPathComponent("url-destination")))
        try await waitUntil { repository.isReady }
        let preview = try await repository.previewImport(batch)
        _ = try await repository.importBatch(batch, preview: preview, expand: false)
        let links = try await repository.query(ClipboardQuery(type: "url"))
        precondition(links.items.map(\.id) == [url.item.id])
        precondition(repository.groups.map(\.name) == ["Saved links"])
        let memberships = [repository.groups[0].id]
        precondition(links.items[0].groupIDs == memberships && links.items[0].customTitle == "Saved link")
        repository.record(ClipboardCapture(type: .text, textContent: link, imageData: nil, filePaths: [],
            sourceAppName: "Fixture", sourceBundleID: "example.fixture", capturedAt: Date()))
        try await waitUntil { repository.items.first?.id == url.item.id && repository.items.first!.lastCopiedAt > url.item.lastCopiedAt }
        let copied = try await repository.item(id: url.item.id)!
        precondition(repository.totalCount == 2 && copied.type == .url && copied.textContent == link)
        precondition(copied.customTitle == "Saved link" && copied.groupIDs == memberships)
        print("PASS: Paste plain-text and native URLs deduplicate as links with titles/groups, prose stays text, and recopying an imported link preserves its record and metadata")
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

    private static func testGroupColors(root: URL, png: Data) async throws {
        let fixture = try PasteImportFixture(directory: root.appendingPathComponent("group-colors-source"))
        let colors: [(UInt64, ClipboardGroupColor)] = [
            (0xF0554D, .red), (0xFA9214, .orange), (0xFAB700, .yellow), (0x52CC64, .green),
            (0x62A9F5, .blue), (0xB663E0, .purple), (0xFA506F, .pink), (0x8F8F93, .gray)
        ]
        for (index, color) in colors.enumerated() {
            fixture.addGroup(id: Int64(index + 1), name: color.1.rawValue,
                             attributes: Data("{\"type\":\"pinboard\",\"colorCode\":\(color.0)}".utf8))
        }
        let invalidAttributes = [
            "{}", "{\"type\":\"pinboard\"}", "{\"type\":\"pinboard\",\"colorCode\":null}",
            "{\"type\":\"pinboard\",\"colorCode\":123}", "{\"type\":\"pinboard\",\"colorCode\":-1}",
            "{\"type\":\"pinboard\",\"colorCode\":\"red\"}", "not JSON",
            "{\"type\":\"clipboard\",\"colorCode\":15750477}", "{\"colorCode\":15750477}"
        ]
        for (index, json) in invalidAttributes.enumerated() {
            fixture.addGroup(id: Int64(100 + index), name: "Uncolored \(index)", attributes: Data(json.utf8))
        }
        fixture.addGroup(id: 200, name: "No attributes")
        fixture.addGroup(id: 201, name: "Merged")
        fixture.addGroup(id: 202, name: "merged", attributes: Data("{\"type\":\"pinboard\",\"colorCode\":16404591}".utf8))
        fixture.addGroup(id: 203, name: "MERGED", attributes: Data("{\"type\":\"pinboard\",\"colorCode\":9408403}".utf8))
        try fixture.add([["public.png": png]], groupID: 1)
        let sourceHashes = try hashes(in: fixture.directory)
        let batch = try await Task.detached { try PasteImportService.scan(directory: fixture.directory) { _, _ in } }.value
        let afterScanHashes = try hashes(in: fixture.directory)
        precondition(afterScanHashes == sourceHashes)
        for (index, color) in colors.enumerated() {
            precondition(batch.groups.first { $0.id == Int64(index + 1) }?.color == color.1)
        }
        precondition(batch.groups.filter { (100...201).contains($0.id) }.allSatisfy { $0.color == nil })
        print("PASS: all eight Paste Pinboard colors decode; missing, malformed, unknown and non-Pinboard attributes stay uncolored; source unchanged")

        let manager = ImportFileManager(root: root.appendingPathComponent("group-colors-destination"))
        let repository = ClipboardRepository(fileManager: manager)
        try await waitUntil { repository.isReady }
        let red = try await repository.saveGroup(name: "RED")
        try await repository.setGroupColor(id: red.id, color: .indigo)
        let orange = try await repository.saveGroup(name: "Orange")
        let preview = try await repository.previewImport(batch)
        precondition(preview.groupColorUpdates == [orange.id: .orange])
        precondition(preview.groupsToCreate.first { $0.name == "Merged" }?.color == .pink,
                     "Same-name source boards use the first known color, including a later color after a missing one")
        let result = try await repository.importBatch(batch, preview: preview, expand: true)
        precondition(result.added == 1 && result.groupColorsUpdated == 1)
        let reloaded = ClipboardRepository(fileManager: manager)
        try await waitUntil { reloaded.groups.count == preview.groupsToCreate.count + 2 }
        precondition(reloaded.groups.first { $0.id == red.id }?.color == .indigo, "Keep existing local colors")
        precondition(reloaded.groups.first { $0.id == orange.id }?.color == .orange)
        for (_, color) in colors.dropFirst(2) {
            precondition(reloaded.groups.first { $0.name == color.rawValue }?.color == color)
        }
        precondition(reloaded.groups.first { $0.name == "Merged" }?.color == .pink)
        let repeated = try await reloaded.previewImport(batch)
        precondition(!repeated.hasChanges)
        print("PASS: new colors and missing local colors persist across restart, existing local colors win, and repeated import has no changes")

        try await repository.setGroupColor(id: orange.id, color: nil)
        let stale = try await repository.previewImport(batch)
        try await repository.setGroupColor(id: orange.id, color: .blue)
        do {
            _ = try await repository.importBatch(batch, preview: stale, expand: true)
            preconditionFailure("Color edits after preview must require a fresh confirmation")
        } catch PasteImportError.stalePreview { }
        try await repository.setGroupColor(id: orange.id, color: nil)
        let viewModel = PasteImportViewModel(repository: repository, isPasteRunning: { false })
        viewModel.selectedDirectory = fixture.directory
        viewModel.scan()
        try await waitUntil { !viewModel.isScanning }
        precondition(viewModel.canImport && viewModel.importCount == 0)
        precondition(viewModel.preview?.groupsToCreate.isEmpty == true && viewModel.preview?.groupUpdates.isEmpty == true)
        precondition(viewModel.preview?.groupColorUpdates == [orange.id: .orange])
        viewModel.importRecords()
        try await waitUntil { !viewModel.isSaving }
        precondition(viewModel.result?.groupColorsUpdated == 1 && viewModel.result?.added == 0)
        print("PASS: color-only reimport is available in the UI; edits after preview are protected")

        let failureManager = ImportFileManager(root: root.appendingPathComponent("group-colors-rollback"))
        let failedRepository = ClipboardRepository(fileManager: failureManager)
        try await waitUntil { failedRepository.isReady }
        let uncolored = try await failedRepository.saveGroup(name: "Red")
        failureManager.failSecondCopy = true
        let failurePreview = try await failedRepository.previewImport(batch)
        do {
            _ = try await failedRepository.importBatch(batch, preview: failurePreview, expand: true)
            preconditionFailure("Asset failure must roll back color updates and new groups")
        } catch PasteImportError.storage { }
        let afterFailure = try await failedRepository.previewImport(batch)
        precondition(afterFailure.existingGroups == [uncolored] && afterFailure.existingHashes.isEmpty)
        precondition(afterFailure.groupColorUpdates == [uncolored.id: .red])
        failureManager.failSecondCopy = false
        let retry = try await failedRepository.importBatch(batch, preview: afterFailure, expand: true)
        precondition(retry.groupColorsUpdated == 1 && retry.added == 1)
        print("PASS: failed import rolls back color backfills together with new groups and history; retry succeeds")
    }

    private static func testSourceIcons(root: URL, png: Data) async throws {
        let fixture = try PasteImportFixture(directory: root.appendingPathComponent("icons-source"))
        fixture.setIcon(png)
        fixture.addApplication(id: 2, bundleID: "example.second", icon: NSImage(data: png)!.tiffRepresentation!)
        fixture.addApplication(id: 3, bundleID: "example.broken", icon: Data([0, 1, 2]))
        fixture.addApplication(id: 4, bundleID: "example.oversized", icon: Data(repeating: 0, count: 4 * 1_024 * 1_024 + 1))
        fixture.addApplication(id: 5, bundleID: "", icon: png)
        fixture.addApplication(id: 6, bundleID: "com.wiheads.paste", icon: png)
        for (index, source) in [1, 1, 2, 3, 4, 5, nil].enumerated() {
            try fixture.add([["public.utf8-plain-text": Data("Icon record \(index)".utf8)]], sourceID: source)
        }
        let sourceBefore = try hashes(in: fixture.directory)
        let batch = try await Task.detached { try PasteImportService.scan(directory: fixture.directory) { _, _ in } }.value
        precondition(batch.entries.count == 7 && batch.skipped.isEmpty)
        precondition(batch.sourceIconBundleIDs == ["example.fixture", "example.second"])
        precondition(batch.entries.filter { $0.item.sourceBundleID.isEmpty }.count == 2, "Missing sources must not borrow Paste's bundle ID or icon")
        let sourceAfter = try hashes(in: fixture.directory)
        precondition(sourceAfter == sourceBefore)
        let manager = ImportFileManager(root: root.appendingPathComponent("icons-destination"))
        let repository = ClipboardRepository(fileManager: manager, installedSourceIcon: { _ in
            preconditionFailure("Import must use Paste's staged icon without querying installed apps")
        })
        try await waitUntil { repository.isReady }
        let iconDirectory = manager.root.appendingPathComponent("PasteLite/SourceAppIcons")
        precondition(!FileManager.default.fileExists(atPath: iconDirectory.path))
        let preview = try await repository.previewImport(batch)
        precondition(!FileManager.default.fileExists(atPath: iconDirectory.path), "Preview must not persist icons")
        let result = try await repository.importBatch(batch, preview: preview, expand: true)
        precondition(result.sourceIconsSaved == 2 && result.sourceIconsFailed == 0 && result.added == 7)
        precondition(repository.sourceIconRevision == 1)
        let savedFiles = try FileManager.default.contentsOfDirectory(atPath: iconDirectory.path)
        precondition(savedFiles.count == 2)
        let iconURL = iconDirectory.appendingPathComponent(SourceAppIcon.filename(for: "example.fixture"))
        let savedData = try Data(contentsOf: iconURL)
        let savedImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(savedData as CFData, nil)!, 0, nil)!
        precondition(savedImage.width == 64 && savedImage.height == 64)
        let repeatPreview = try await repository.previewImport(batch)
        precondition(!repeatPreview.hasChanges)
        let repeatResult = try await repository.importBatch(batch, preview: repeatPreview, expand: true)
        precondition(repeatResult.sourceIconsSaved == 0 && repository.sourceIconRevision == 1)
        let repeatedData = try Data(contentsOf: iconURL)
        precondition(repeatedData == savedData)
        let differentIcon = NSBitmapImageRep(data: png)!
        for y in 0..<differentIcon.pixelsHigh { for x in 0..<differentIcon.pixelsWide { differentIcon.setColor(.red, atX: x, y: y) } }
        fixture.setIcon(differentIcon.representation(using: .png, properties: [:])!)
        let changedBatch = try await Task.detached { try PasteImportService.scan(directory: fixture.directory) { _, _ in } }.value
        let changedResult = try await repository.importBatch(changedBatch, preview: repository.previewImport(changedBatch), expand: true)
        let preservedData = try Data(contentsOf: iconURL)
        precondition(changedResult.sourceIconsSaved == 0 && preservedData == savedData, "An imported icon must not replace a saved local icon")
        let reopened = ClipboardRepository(fileManager: manager, installedSourceIcon: { _ in nil })
        try await waitUntil { reopened.isReady }
        let reopenedIcon = await reopened.sourceIconURL(for: "example.fixture")
        precondition(reopenedIcon == iconURL)
        print("PASS: Paste PNG/TIFF icons persist during import without installed apps; malformed/oversized/unknown icons do not drop history; shared files survive restart")

        let oldFixture = try PasteImportFixture(directory: root.appendingPathComponent("icons-backfill-source"))
        try oldFixture.add([["public.utf8-plain-text": Data("Previously imported".utf8)]])
        let oldBatch = try await Task.detached { try PasteImportService.scan(directory: oldFixture.directory) { _, _ in } }.value
        let oldManager = ImportFileManager(root: root.appendingPathComponent("icons-backfill"))
        let oldRepository = ClipboardRepository(fileManager: oldManager, installedSourceIcon: { _ in nil })
        try await waitUntil { oldRepository.isReady }
        _ = try await oldRepository.importBatch(oldBatch, preview: oldRepository.previewImport(oldBatch), expand: true)
        let previousItems = oldRepository.items
        let missingIcon = await oldRepository.sourceIconURL(for: "example.fixture")
        precondition(missingIcon == nil)
        oldFixture.setIcon(png)
        let viewModel = PasteImportViewModel(repository: oldRepository, isPasteRunning: { false })
        viewModel.selectedDirectory = oldFixture.directory
        viewModel.scan()
        try await waitUntil { !viewModel.isScanning }
        precondition(viewModel.canImport && viewModel.importCount == 0)
        precondition(viewModel.preview?.sourceIconUpdates == ["example.fixture"])
        viewModel.importRecords()
        try await waitUntil { !viewModel.isSaving }
        precondition(viewModel.result?.sourceIconsSaved == 1 && viewModel.result?.added == 0)
        precondition(oldRepository.items == previousItems && oldRepository.sourceIconRevision == 1)
        let backfilled = await oldRepository.sourceIconURL(for: "example.fixture")
        precondition(backfilled != nil)
        print("PASS: icon-only reimport stays actionable, recovers negative cache, refreshes visible rows and preserves record metadata")

        let collisionManager = ImportFileManager(root: root.appendingPathComponent("icons-other-source"))
        let collisionRepository = ClipboardRepository(fileManager: collisionManager, installedSourceIcon: { _ in nil })
        try await waitUntil { collisionRepository.isReady }
        collisionRepository.record(ClipboardCapture(type: .text, textContent: "Previously imported", imageData: nil, filePaths: [], sourceAppName: "Other", sourceBundleID: "example.other", capturedAt: Date()))
        try await waitUntil { collisionRepository.items.count == 1 }
        let collisionBatch = try await Task.detached { try PasteImportService.scan(directory: oldFixture.directory) { _, _ in } }.value
        let collisionPreview = try await collisionRepository.previewImport(collisionBatch)
        precondition(!collisionPreview.hasChanges && collisionPreview.sourceIconUpdates.isEmpty)
        let collisionResult = try await collisionRepository.importBatch(collisionBatch, preview: collisionPreview, expand: true)
        precondition(collisionResult.sourceIconsSaved == 0 && collisionRepository.items[0].sourceBundleID == "example.other")
        precondition(!FileManager.default.fileExists(atPath: collisionManager.root.appendingPathComponent("PasteLite/SourceAppIcons").path))
        print("PASS: content deduplication preserves the local source and never attaches another app's imported icon")

        let failureFixture = try PasteImportFixture(directory: root.appendingPathComponent("icons-failure-source"))
        failureFixture.setIcon(png)
        try failureFixture.add([["public.png": png]])
        let failureBatch = try await Task.detached { try PasteImportService.scan(directory: failureFixture.directory) { _, _ in } }.value
        let failureManager = ImportFileManager(root: root.appendingPathComponent("icons-failure"))
        let failed = ClipboardRepository(fileManager: failureManager, installedSourceIcon: { _ in nil })
        try await waitUntil { failed.isReady }
        failureManager.failSecondCopy = true
        let failurePreview = try await failed.previewImport(failureBatch)
        do {
            _ = try await failed.importBatch(failureBatch, preview: failurePreview, expand: true)
            preconditionFailure("Content copy failure must roll back import")
        } catch PasteImportError.storage { }
        let blockedDirectory = failureManager.root.appendingPathComponent("PasteLite/SourceAppIcons")
        precondition(!FileManager.default.fileExists(atPath: blockedDirectory.path) && failed.items.isEmpty)
        failureManager.failSecondCopy = false
        try Data([0]).write(to: blockedDirectory)
        let partial = try await failed.importBatch(failureBatch, preview: failurePreview, expand: true)
        precondition(partial.added == 1 && partial.sourceIconsSaved == 0 && partial.sourceIconsFailed == 1)
        try FileManager.default.removeItem(at: blockedDirectory)
        let retryPreview = try await failed.previewImport(failureBatch)
        precondition(retryPreview.hasChanges && retryPreview.sourceIconUpdates == ["example.fixture"])
        let retry = try await failed.importBatch(failureBatch, preview: retryPreview, expand: true)
        precondition(retry.added == 0 && retry.sourceIconsSaved == 1 && retry.sourceIconsFailed == 0)
        print("PASS: failed history import leaves no icons; icon write failure reports partial success and supports icon-only retry")

        let limitedManager = ImportFileManager(root: root.appendingPathComponent("icons-capacity"))
        let limited = ClipboardRepository(fileManager: limitedManager, installedSourceIcon: { _ in nil })
        try await waitUntil { limited.isReady }
        try await limited.updateLimits(ClipboardLimits(itemCount: 1))
        let limitedPreview = try await limited.previewImport(batch)
        let limitedResult = try await limited.importBatch(batch, preview: limitedPreview, expand: false)
        precondition(limitedResult.added == 1 && limitedResult.sourceIconsSaved == 0)
        precondition(!FileManager.default.fileExists(atPath: limitedManager.root.appendingPathComponent("PasteLite/SourceAppIcons").path))
        print("PASS: capacity-skipped records do not leave orphan source icons")
    }

    private static func testWindowFocus(root: URL, repository: ClipboardRepository, source: URL) async throws {
        let started = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let viewModel = PasteImportViewModel(repository: repository, isPasteRunning: { false }, directorySearch: {
            started.signal()
            precondition(resume.wait(timeout: .now() + 10) == .success)
            return [source]
        })
        precondition(started.wait(timeout: .now()) == .timedOut, "Constructing the model must not probe protected directories")
        let controller = PasteImportWindowController(viewModel: viewModel, onShowHistory: {})
        let window = controller.window!
        let coveringWindow = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 540, height: 630),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
        coveringWindow.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        NSApp.setActivationPolicy(.prohibited)
        defer { coveringWindow.close(); controller.close() }
        var focusRequests = 0
        let restoreFocus = viewModel.onRestoreFocus
        viewModel.onRestoreFocus = { focusRequests += 1; restoreFocus?() }
        controller.showWindow(nil)
        try await waitUntil { started.wait(timeout: .now()) == .success }
        precondition(window.isVisible && viewModel.isFindingDirectories)
        coveringWindow.orderFront(nil)
        precondition(coveringWindow.orderedIndex < window.orderedIndex)
        resume.signal()
        try await waitUntil { !viewModel.isFindingDirectories && window.orderedIndex < coveringWindow.orderedIndex }
        precondition(focusRequests == 1 && viewModel.selectedDirectory == source)
        focusRequests = 0
        coveringWindow.orderFront(nil)
        viewModel.scan()
        try await waitUntil { !viewModel.isScanning }
        precondition(viewModel.preview != nil && focusRequests == 1, "Scan progress must restore focus only once")
        try await waitUntil { window.orderedIndex < coveringWindow.orderedIndex }
        coveringWindow.orderFront(nil)
        await Task.yield()
        precondition(coveringWindow.orderedIndex < window.orderedIndex, "Completed scans must not keep raising the import window")
        focusRequests = 0
        viewModel.selectDirectory(root.appendingPathComponent("missing-permission-fixture"))
        viewModel.scan()
        try await waitUntil { !viewModel.isScanning }
        precondition(focusRequests == 1 && viewModel.message != nil && viewModel.preview == nil)
        controller.close()
        restoreFocus?()
        await Task.yield()
        precondition(!window.isVisible, "A delayed access callback must not reopen a closed import window")
        print("PASS: directory probing waits for a visible window; access success/failure restores its order once; later progress and closed windows do not steal focus")

        let cancelledStarted = DispatchSemaphore(value: 0), cancelledResume = DispatchSemaphore(value: 0)
        let cancelledFinished = DispatchSemaphore(value: 0)
        let cancelledModel = PasteImportViewModel(repository: repository, directorySearch: {
            cancelledStarted.signal()
            precondition(cancelledResume.wait(timeout: .now() + 10) == .success)
            cancelledFinished.signal()
            return [source]
        })
        var cancelledFocusRequests = 0
        cancelledModel.onRestoreFocus = { cancelledFocusRequests += 1 }
        cancelledModel.findDirectories()
        try await waitUntil { cancelledStarted.wait(timeout: .now()) == .success }
        cancelledModel.cancelScan()
        cancelledResume.signal()
        try await waitUntil { cancelledFinished.wait(timeout: .now()) == .success }
        await Task.yield()
        precondition(!cancelledModel.isFindingDirectories && cancelledModel.directories.isEmpty && cancelledFocusRequests == 0)
        print("PASS: closing while permission/discovery is pending discards late directory results and focus requests")
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
