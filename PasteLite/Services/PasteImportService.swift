import AppKit
import Foundation
import ImageIO
import SQLite3
import zlib

/// Reads the Core Data / compressed JSON layout verified against Paste 6.0.3.
/// It never loads Paste's code, migrates its store, or writes to its pasteboard.
enum PasteImportService {
    private struct PasteboardItem: Decodable {
        let types: [String]
        let dataByType: [String: Data]
    }

    private enum ItemError: Error {
        case skipped(String)
    }

    private static let entityHashes = [
        "ApplicationEntity": "81a4089f6fcd2002a422c9441d7b769abd405f1275aa09e12bd5fcd38987225d",
        "ItemDataEntity": "8102715aa1cbaae37a8a0049240a67996f9d6b314b5cd34aafd71a167cdb8e57",
        "ItemEntity": "d0cedc9c3f7f56a3b93d6f344357ecf67d912798cddd63d737e1394b168b9e30",
        "ListEntity": "6ae4140d07dc19df96823620e241b0fc8d923918340a0e73cb6e6ae530376708"
    ]

    static var candidateDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Containers/com.wiheads.paste/Data/Library/Application Support/Paste"),
            home.appendingPathComponent("Library/Application Support/Paste")
        ].filter { FileManager.default.isReadableFile(atPath: $0.appendingPathComponent("db.sqlite").path) }
    }

    static func removeExpiredTemporaryFiles() {
        let root = FileManager.default.temporaryDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for file in files where file.lastPathComponent.hasPrefix("PasteLite-import-") {
            if let created = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate,
               created < Date().addingTimeInterval(-86_400) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    static func scan(directory: URL, limits: ClipboardLimits = .default, progress: @Sendable (Int, Int) -> Void) throws -> PasteImportBatch {
        let manager = FileManager.default
        let databaseURL = directory.appendingPathComponent("db.sqlite")
        let sourceDates = modificationDates(databaseURL)
        let temporary = manager.temporaryDirectory.appendingPathComponent("PasteLite-import-\(UUID())", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        var succeeded = false
        defer { if !succeeded { try? manager.removeItem(at: temporary) } }

        let snapshot = temporary.appendingPathComponent("source.sqlite")
        try snapshotDatabase(from: databaseURL, to: snapshot)
        var database: OpaquePointer?
        // This private snapshot may need SQLite's WAL sidecars; the source connection stays read-only.
        guard sqlite3_open_v2(snapshot.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw PasteImportError.unreadable
        }
        defer { sqlite3_close(database) }
        try validateSchema(database)
        // Paste 6.0.3 ListType: unknown = 0, clipboard = 1, pinboard = 2.
        let groupQuery = try statement("SELECT Z_PK, ZNAME FROM ZLISTENTITY WHERE ZRAWTYPE = 2 ORDER BY Z_PK", database: database)
        defer { sqlite3_finalize(groupQuery) }
        var groups: [PasteImportGroup] = []
        var groupResult = sqlite3_step(groupQuery)
        while groupResult == SQLITE_ROW {
            try Task.checkCancellation()
            let name = string(groupQuery, column: 1).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw PasteImportError.unsupportedStore }
            groups.append(PasteImportGroup(id: sqlite3_column_int64(groupQuery, 0), name: name))
            groupResult = sqlite3_step(groupQuery)
        }
        guard groupResult == SQLITE_DONE else { throw PasteImportError.unreadable }
        let groupIDs = Set(groups.map(\.id))

        let countStatement = try statement("SELECT count(*) FROM ZITEMENTITY", database: database)
        defer { sqlite3_finalize(countStatement) }
        guard sqlite3_step(countStatement) == SQLITE_ROW else { throw PasteImportError.unreadable }
        let total = Int(sqlite3_column_int64(countStatement, 0))
        let query = try statement("""
            SELECT i.ZCREATEDAT, i.ZTIMESTAMP, a.ZNAME, a.ZBUNDLEIDENTIFIER, d.ZRAWPASTEBOARDITEMS, i.ZLIST, i.ZTITLE
            FROM ZITEMENTITY i
            LEFT JOIN ZAPPLICATIONENTITY a ON a.Z_PK = i.ZSOURCEAPPLICATION
            LEFT JOIN ZITEMDATAENTITY d ON d.Z_PK = i.ZDATA
            ORDER BY COALESCE(i.ZTIMESTAMP, i.ZCREATEDAT) DESC, i.Z_PK DESC
            """, database: database)
        defer { sqlite3_finalize(query) }
        var entries: [String: PasteImportEntry] = [:]
        var skipped: [String: Int] = [:]
        var duplicates = 0
        var processed = 0
        progress(0, total)
        var result = sqlite3_step(query)
        while result == SQLITE_ROW {
            try Task.checkCancellation()
            do {
                let created = try date(query, column: 0)
                let copied = sqlite3_column_type(query, 1) == SQLITE_NULL ? created : try date(query, column: 1)
                guard let encoded = blob(query, column: 4) else { throw ItemError.skipped("缺少本地内容") }
                let payload = try decodeStoredData(encoded, directory: directory)
                let parts: [PasteboardItem]
                do { parts = try JSONDecoder().decode([PasteboardItem].self, from: payload) }
                catch { throw ItemError.skipped("内容编码无法识别") }
                let capture = try capture(parts, source: string(query, column: 2), bundleID: string(query, column: 3), date: copied, limits: limits)
                guard let prepared = PreparedCapture.prepare(capture, limits: limits) else { throw ItemError.skipped("图片无效或超过收录大小限制") }
                let listID = sqlite3_column_int64(query, 5)
                let memberships: Set<Int64> = sqlite3_column_type(query, 5) != SQLITE_NULL && groupIDs.contains(listID) ? [listID] : []
                let title = string(query, column: 6).trimmingCharacters(in: .whitespacesAndNewlines)
                let customTitle = title.isEmpty ? nil : title
                if var existing = entries[prepared.contentHash] {
                    existing.item = ClipboardItem(
                        id: existing.item.id, type: existing.item.type, textContent: existing.item.textContent,
                        assetFilename: existing.item.assetFilename, thumbnailFilename: existing.item.thumbnailFilename,
                        filePaths: existing.item.filePaths, sourceAppName: existing.item.sourceAppName,
                        sourceBundleID: existing.item.sourceBundleID, contentHash: existing.item.contentHash,
                        createdAt: min(created, existing.item.createdAt), lastCopiedAt: existing.item.lastCopiedAt,
                        customTitle: existing.item.customTitle ?? customTitle
                    )
                    existing.groupIDs.formUnion(memberships)
                    entries[prepared.contentHash] = existing
                    duplicates += 1
                } else {
                    let filename = prepared.imageData.map { _ in "\(prepared.contentHash).png" }
                    let thumbnail = prepared.thumbnailData.map { _ in "\(prepared.contentHash)-thumb.png" }
                    try checkDiskSpace(at: temporary, required: prepared.byteCount + 10 * 1_024 * 1_024)
                    if let filename, let data = prepared.imageData { try data.write(to: temporary.appendingPathComponent(filename), options: .atomic) }
                    if let thumbnail, let data = prepared.thumbnailData { try data.write(to: temporary.appendingPathComponent(thumbnail), options: .atomic) }
                    let item = ClipboardItem(
                        id: UUID(), type: prepared.type, textContent: prepared.textContent,
                        assetFilename: filename, thumbnailFilename: thumbnail, filePaths: prepared.filePaths,
                        sourceAppName: prepared.sourceAppName, sourceBundleID: prepared.sourceBundleID,
                        contentHash: prepared.contentHash, createdAt: created, lastCopiedAt: copied,
                        customTitle: customTitle
                    )
                    entries[prepared.contentHash] = PasteImportEntry(item: item, byteCount: prepared.byteCount, groupIDs: memberships)
                }
            } catch ItemError.skipped(let reason) {
                skipped[reason, default: 0] += 1
            }
            processed += 1
            if processed % 20 == 0 || processed == total { progress(processed, total) }
            result = sqlite3_step(query)
        }
        guard result == SQLITE_DONE else { throw PasteImportError.unreadable }
        guard sourceDates == modificationDates(databaseURL) else { throw PasteImportError.sourceChanged }
        try Task.checkCancellation()
        try? manager.removeItem(at: snapshot)
        succeeded = true
        return PasteImportBatch(
            directory: temporary,
            entries: entries.values.sorted { $0.item.lastCopiedAt > $1.item.lastCopiedAt },
            total: total, duplicates: duplicates, skipped: skipped, limits: limits, groups: groups
        )
    }

    static func checkDiskSpace(at directory: URL, required: Int64) throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        if let free = attributes[.systemFreeSize] as? NSNumber, free.int64Value < required {
            throw PasteImportError.insufficientSpace
        }
    }

    private static func modificationDates(_ database: URL) -> [Date?] {
        [database, URL(fileURLWithPath: database.path + "-wal")].map {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
    }

    private static func snapshotDatabase(from source: URL, to destination: URL) throws {
        var input: OpaquePointer?
        var output: OpaquePointer?
        defer {
            if let input { sqlite3_close(input) }
            if let output { sqlite3_close(output) }
        }
        guard sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_open_v2(destination.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw PasteImportError.unreadable
        }
        let sourceSize = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        try checkDiskSpace(at: destination.deletingLastPathComponent(), required: Int64(sourceSize) + 10 * 1_024 * 1_024)
        guard let backup = sqlite3_backup_init(output, "main", input, "main") else { throw PasteImportError.unreadable }
        defer { sqlite3_backup_finish(backup) }
        let deadline = Date().addingTimeInterval(10)
        while true {
            try Task.checkCancellation()
            let result = sqlite3_backup_step(backup, 256)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_OK || result == SQLITE_BUSY || result == SQLITE_LOCKED,
                  Date() < deadline else { throw PasteImportError.unreadable }
            if result != SQLITE_OK { Thread.sleep(forTimeInterval: 0.05) }
        }
    }

    private static func validateSchema(_ database: OpaquePointer?) throws {
        let query = try statement("SELECT Z_PLIST FROM Z_METADATA LIMIT 1", database: database)
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW, let metadata = blob(query, column: 0),
              let plist = try? PropertyListSerialization.propertyList(from: metadata, format: nil) as? [String: Any],
              let hashes = plist["NSStoreModelVersionHashes"] as? [String: Data],
              entityHashes.allSatisfy({ name, hash in hashes[name]?.map { String(format: "%02x", $0) }.joined() == hash }) else {
            throw PasteImportError.unsupportedStore
        }
    }

    private static func statement(_ sql: String, database: OpaquePointer?) throws -> OpaquePointer {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &query, nil) == SQLITE_OK, let query else {
            if let query { sqlite3_finalize(query) }
            throw PasteImportError.unsupportedStore
        }
        return query
    }

    private static func blob(_ query: OpaquePointer, column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(query, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, column)))
    }

    private static func string(_ query: OpaquePointer, column: Int32) -> String {
        guard let text = sqlite3_column_text(query, column) else { return "" }
        return String(cString: text)
    }

    private static func date(_ query: OpaquePointer, column: Int32) throws -> Date {
        guard sqlite3_column_type(query, column) != SQLITE_NULL else { throw ItemError.skipped("缺少有效时间") }
        let value = sqlite3_column_double(query, column)
        guard value.isFinite, value >= 0, value < Date().timeIntervalSinceReferenceDate + 86_400 else {
            throw ItemError.skipped("缺少有效时间")
        }
        return Date(timeIntervalSinceReferenceDate: value)
    }

    private static func decodeStoredData(_ data: Data, directory: URL) throws -> Data {
        guard let marker = data.first else { throw ItemError.skipped("缺少本地内容") }
        let compressed: Data
        switch marker {
        case 1: compressed = data.dropFirst()
        case 2:
            let name = String(data: data.dropFirst().filter { $0 != 0 }, encoding: .utf8) ?? ""
            guard UUID(uuidString: name) != nil else { throw ItemError.skipped("附件引用无效") }
            let root = directory.appendingPathComponent(".db_SUPPORT/_EXTERNAL_DATA").resolvingSymlinksInPath()
            let file = root.appendingPathComponent(name).resolvingSymlinksInPath()
            guard root.path.hasPrefix(directory.resolvingSymlinksInPath().path + "/"),
                  file.deletingLastPathComponent() == root,
                  let stored = try? Data(contentsOf: file) else { throw ItemError.skipped("附件缺失或过大") }
            compressed = stored
        default: throw ItemError.skipped("内容编码无法识别")
        }
        return try inflateData(compressed)
    }

    private static func inflateData(_ data: Data) throws -> Data {
        guard data.count <= Int(UInt32.max) else { throw ItemError.skipped("附件缺失或过大") }
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ItemError.skipped("内容解压失败")
        }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                try Task.checkCancellation()
                let result = buffer.withUnsafeMutableBytes { bytes -> Int32 in
                    stream.next_out = bytes.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(bytes.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let count = buffer.count - Int(stream.avail_out)
                output.append(contentsOf: buffer.prefix(count))
                if result == Z_STREAM_END { return output }
                guard result == Z_OK, count > 0 else { throw ItemError.skipped("内容解压失败") }
            }
        }
    }

    private static func capture(_ parts: [PasteboardItem], source: String, bundleID: String, date: Date, limits: ClipboardLimits) throws -> ClipboardCapture {
        guard !parts.isEmpty else { throw ItemError.skipped("缺少本地内容") }
        let ignored = Set(["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"])
        guard parts.allSatisfy({ ignored.isDisjoint(with: $0.types) }) else { throw ItemError.skipped("内容标记为机密或临时") }
        let name = source.isEmpty ? "Paste（导入）" : source
        let identifier = bundleID.isEmpty ? "com.wiheads.paste" : bundleID
        let fileURLs = parts.compactMap { part -> URL? in
            guard let data = part.dataByType["public.file-url"], let text = String(data: data, encoding: .utf8) else { return nil }
            return URL(string: text.trimmingCharacters(in: .controlCharacters))
        }
        if parts.contains(where: { $0.dataByType["public.file-url"] != nil }) {
            guard fileURLs.count == parts.count,
                  fileURLs.allSatisfy({ $0.isFileURL && FileManager.default.isReadableFile(atPath: $0.path) }) else {
                throw ItemError.skipped("文件引用已失效")
            }
            return ClipboardCapture(type: .file, textContent: nil, imageData: nil, filePaths: fileURLs.map(\.path), sourceAppName: name, sourceBundleID: identifier, capturedAt: date)
        }
        guard parts.count == 1 else { throw ItemError.skipped("暂不支持的多项组合内容") }
        let values = parts[0].dataByType
        for type in ["public.png", "public.tiff", "public.jpeg"] {
            if let data = values[type] {
                guard let image = CGImageSourceCreateWithData(data as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0, width <= Int.max / height / 4 else {
                    throw ItemError.skipped("图片无效或尺寸过大")
                }
                return ClipboardCapture(type: .image, textContent: nil, imageData: data, filePaths: [], sourceAppName: name, sourceBundleID: identifier, capturedAt: date)
            }
        }
        var type: ClipboardContentType = .text
        var text: String?
        if let data = values["public.url"], let value = String(data: data, encoding: .utf8),
           let url = URL(string: value), url.scheme != nil, !url.isFileURL {
            text = value
            type = .url
        }
        if text == nil {
            for key in ["public.utf8-plain-text", "public.plain-text", "public.text", "public.utf16-external-plain-text", "public.utf16-plain-text"] {
                if let data = values[key], let value = String(data: data, encoding: key.contains("utf16") ? .utf16 : .utf8) {
                    text = value
                    break
                }
            }
        }
        // RTF has no web execution. HTML-only entries are skipped instead of invoking a web renderer.
        if text == nil, let data = values["public.rtf"] {
            text = NSAttributedString(rtf: data, documentAttributes: nil)?.string
        }
        guard let text, !text.isEmpty else { throw ItemError.skipped("缺少可用文本或不支持的格式") }
        guard limits.allowsText(bytes: text.utf8.count) else { throw ItemError.skipped("文本超过收录大小限制") }
        return ClipboardCapture(type: type, textContent: text, imageData: nil, filePaths: [], sourceAppName: name, sourceBundleID: identifier, capturedAt: date)
    }
}
