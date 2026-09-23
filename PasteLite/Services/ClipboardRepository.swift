import Combine
import CryptoKit
import Foundation
import ImageIO
import SwiftData
import UniformTypeIdentifiers

@Model
final class ClipboardRecord {
    @Attribute(.unique) var contentHash: String
    var id: UUID
    var typeRawValue: String
    var textContent: String?
    var assetFilename: String?
    var thumbnailFilename: String?
    var filePathsData: Data
    var sourceAppName: String
    var sourceBundleID: String
    var createdAt: Date
    var lastCopiedAt: Date
    var byteCount: Int64

    init(item: ClipboardItem, byteCount: Int64) {
        contentHash = item.contentHash
        id = item.id
        typeRawValue = item.type.rawValue
        textContent = item.textContent
        assetFilename = item.assetFilename
        thumbnailFilename = item.thumbnailFilename
        filePathsData = (try? JSONEncoder().encode(item.filePaths)) ?? Data()
        sourceAppName = item.sourceAppName
        sourceBundleID = item.sourceBundleID
        createdAt = item.createdAt
        lastCopiedAt = item.lastCopiedAt
        self.byteCount = byteCount
    }

    var item: ClipboardItem {
        ClipboardItem(
            id: id,
            type: ClipboardContentType(rawValue: typeRawValue) ?? .text,
            textContent: textContent,
            assetFilename: assetFilename,
            thumbnailFilename: thumbnailFilename,
            filePaths: (try? JSONDecoder().decode([String].self, from: filePathsData)) ?? [],
            sourceAppName: sourceAppName,
            sourceBundleID: sourceBundleID,
            contentHash: contentHash,
            createdAt: createdAt,
            lastCopiedAt: lastCopiedAt
        )
    }
}

private struct PreparedCapture {
    let type: ClipboardContentType
    let textContent: String?
    let imageData: Data?
    let thumbnailData: Data?
    let filePaths: [String]
    let sourceAppName: String
    let sourceBundleID: String
    let contentHash: String
    let capturedAt: Date
    let byteCount: Int64
}

private struct StorageUpdate {
    let item: ClipboardItem
    let removedIDs: Set<UUID>
}

private final class ClipboardStorage {
    private let maximumItemCount = 1_000
    private let maximumStorageBytes: Int64 = 500 * 1_024 * 1_024
    private let maximumImageBytes = 25 * 1_024 * 1_024

    private let queue = DispatchQueue(label: "com.local.PasteLite.storage", qos: .utility)
    private let fileManager: FileManager
    private let container: ModelContainer
    private let baseDirectory: URL
    private let assetsDirectory: URL
    private let thumbnailsDirectory: URL
    private let legacyHistoryFile: URL

    init(fileManager: FileManager) throws {
        self.fileManager = fileManager

        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        baseDirectory = applicationSupport.appendingPathComponent("PasteLite", isDirectory: true)
        assetsDirectory = baseDirectory.appendingPathComponent("Assets", isDirectory: true)
        thumbnailsDirectory = baseDirectory.appendingPathComponent("Thumbnails", isDirectory: true)
        legacyHistoryFile = baseDirectory.appendingPathComponent("history.json")

        try fileManager.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)

        let schema = Schema([ClipboardRecord.self])
        let configuration = ModelConfiguration(
            "PasteLite",
            schema: schema,
            url: baseDirectory.appendingPathComponent("history.store"),
            allowsSave: true,
            cloudKitDatabase: .none
        )
        container = try ModelContainer(for: schema, configurations: [configuration])
    }

    func load(completion: @escaping (Result<[ClipboardItem], Error>) -> Void) {
        queue.async { [self] in
            do {
                let context = makeContext()
                try migrateLegacyHistoryIfNeeded(context: context)
                _ = try trimIfNeeded(context: context)

                var descriptor = FetchDescriptor<ClipboardRecord>(
                    sortBy: [SortDescriptor(\ClipboardRecord.lastCopiedAt, order: .reverse)]
                )
                descriptor.fetchLimit = maximumItemCount
                let records = try context.fetch(descriptor)
                removeOrphanedAssets(records: records)
                complete(.success(records.map(\.item)), using: completion)
            } catch {
                complete(.failure(error), using: completion)
            }
        }
    }

    func record(
        _ capture: ClipboardCapture,
        completion: @escaping (Result<StorageUpdate?, Error>) -> Void
    ) {
        queue.async { [self] in
            do {
                guard let prepared = prepare(capture) else {
                    complete(.success(nil), using: completion)
                    return
                }

                let context = makeContext()
                let contentHash = prepared.contentHash
                let descriptor = FetchDescriptor<ClipboardRecord>(
                    predicate: #Predicate { $0.contentHash == contentHash }
                )

                let record: ClipboardRecord
                if let existing = try context.fetch(descriptor).first {
                    existing.sourceAppName = prepared.sourceAppName
                    existing.sourceBundleID = prepared.sourceBundleID
                    existing.lastCopiedAt = prepared.capturedAt
                    record = existing
                } else {
                    let assetFilename = try writeImageIfNeeded(prepared)
                    let thumbnailFilename = try writeThumbnailIfNeeded(prepared)
                    let item = ClipboardItem(
                        id: UUID(),
                        type: prepared.type,
                        textContent: prepared.textContent,
                        assetFilename: assetFilename,
                        thumbnailFilename: thumbnailFilename,
                        filePaths: prepared.filePaths,
                        sourceAppName: prepared.sourceAppName,
                        sourceBundleID: prepared.sourceBundleID,
                        contentHash: prepared.contentHash,
                        createdAt: prepared.capturedAt,
                        lastCopiedAt: prepared.capturedAt
                    )
                    let newRecord = ClipboardRecord(item: item, byteCount: prepared.byteCount)
                    context.insert(newRecord)
                    record = newRecord
                }

                if record.typeRawValue == ClipboardContentType.image.rawValue {
                    if record.assetFilename == nil {
                        record.assetFilename = try writeImageIfNeeded(prepared)
                    }
                    if record.thumbnailFilename == nil {
                        record.thumbnailFilename = try writeThumbnailIfNeeded(prepared)
                    }
                    record.byteCount = prepared.byteCount
                }

                try context.save()
                let removedIDs = try trimIfNeeded(context: context)
                complete(
                    .success(StorageUpdate(item: record.item, removedIDs: removedIDs)),
                    using: completion
                )
            } catch {
                complete(.failure(error), using: completion)
            }
        }
    }

    func markUsed(id: UUID, at date: Date, completion: @escaping (Error?) -> Void) {
        queue.async { [self] in
            do {
                let context = makeContext()
                let descriptor = FetchDescriptor<ClipboardRecord>(
                    predicate: #Predicate { $0.id == id }
                )
                if let record = try context.fetch(descriptor).first {
                    record.lastCopiedAt = date
                    try context.save()
                }
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    func assetURL(for item: ClipboardItem) -> URL? {
        item.assetFilename.map { assetsDirectory.appendingPathComponent($0) } ?? item.imageFileURL
    }

    func previewURL(for item: ClipboardItem) -> URL? {
        if let filename = item.thumbnailFilename {
            let thumbnailURL = thumbnailsDirectory.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: thumbnailURL.path) {
                return thumbnailURL
            }
        }
        return assetURL(for: item)
    }

    private func makeContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func prepare(_ capture: ClipboardCapture) -> PreparedCapture? {
        let payload: Data
        var imageData: Data?
        var thumbnailData: Data?

        switch capture.type {
        case .text, .url:
            guard let text = capture.textContent else { return nil }
            payload = Data(text.utf8)

        case .file:
            payload = Data(capture.filePaths.joined(separator: "\u{0}").utf8)

        case .image:
            guard let sourceData = capture.imageData,
                  let pngData = normalizedPNGData(sourceData),
                  pngData.count <= maximumImageBytes else {
                return nil
            }
            payload = pngData
            imageData = pngData
            thumbnailData = makeThumbnailData(sourceData)
        }

        let contentHash = hash(type: capture.type, data: payload)
        return PreparedCapture(
            type: capture.type,
            textContent: capture.textContent,
            imageData: imageData,
            thumbnailData: thumbnailData,
            filePaths: capture.filePaths,
            sourceAppName: capture.sourceAppName,
            sourceBundleID: capture.sourceBundleID,
            contentHash: contentHash,
            capturedAt: capture.capturedAt,
            byteCount: Int64(payload.count + (thumbnailData?.count ?? 0))
        )
    }

    private func normalizedPNGData(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if CGImageSourceGetType(source) as String? == UTType.png.identifier {
            return data
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private func makeThumbnailData(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private func hash(type: ClipboardContentType, data: Data) -> String {
        var typedData = Data(type.rawValue.utf8)
        typedData.append(0)
        typedData.append(data)
        return SHA256.hash(data: typedData).map { String(format: "%02x", $0) }.joined()
    }

    private func writeImageIfNeeded(_ capture: PreparedCapture) throws -> String? {
        guard let imageData = capture.imageData else { return nil }
        let filename = "\(capture.contentHash).png"
        let destination = assetsDirectory.appendingPathComponent(filename)
        if !fileManager.fileExists(atPath: destination.path) {
            try imageData.write(to: destination, options: .atomic)
        }
        return filename
    }

    private func writeThumbnailIfNeeded(_ capture: PreparedCapture) throws -> String? {
        guard let thumbnailData = capture.thumbnailData else { return nil }
        let filename = "\(capture.contentHash)-thumb.png"
        let destination = thumbnailsDirectory.appendingPathComponent(filename)
        if !fileManager.fileExists(atPath: destination.path) {
            try thumbnailData.write(to: destination, options: .atomic)
        }
        return filename
    }

    private func trimIfNeeded(context: ModelContext) throws -> Set<UUID> {
        let descriptor = FetchDescriptor<ClipboardRecord>(
            sortBy: [SortDescriptor(\ClipboardRecord.lastCopiedAt, order: .reverse)]
        )
        let records = try context.fetch(descriptor)
        var retainedBytes: Int64 = 0
        var removedIDs = Set<UUID>()
        var removedAssetURLs: [URL] = []

        for (index, record) in records.enumerated() {
            let exceedsCount = index >= maximumItemCount
            let exceedsStorage = retainedBytes + record.byteCount > maximumStorageBytes
            if exceedsCount || exceedsStorage {
                removedIDs.insert(record.id)
                if let filename = record.assetFilename {
                    removedAssetURLs.append(assetsDirectory.appendingPathComponent(filename))
                }
                if let filename = record.thumbnailFilename {
                    removedAssetURLs.append(thumbnailsDirectory.appendingPathComponent(filename))
                }
                context.delete(record)
            } else {
                retainedBytes += record.byteCount
            }
        }

        guard !removedIDs.isEmpty else { return [] }
        try context.save()
        removedAssetURLs.forEach { try? fileManager.removeItem(at: $0) }
        return removedIDs
    }

    private func migrateLegacyHistoryIfNeeded(context: ModelContext) throws {
        guard try context.fetchCount(FetchDescriptor<ClipboardRecord>()) == 0,
              fileManager.fileExists(atPath: legacyHistoryFile.path) else {
            return
        }

        let data = try Data(contentsOf: legacyHistoryFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let oldItems = try decoder.decode([ClipboardItem].self, from: data)

        for var item in oldItems {
            var byteCount = item.textContent.map { Int64($0.utf8.count) }
                ?? Int64(item.filePaths.joined(separator: "\u{0}").utf8.count)

            if item.type == .image, let assetFilename = item.assetFilename {
                let assetURL = assetsDirectory.appendingPathComponent(assetFilename)
                let imageData = try? Data(contentsOf: assetURL)
                byteCount = Int64(imageData?.count ?? 0)

                if let imageData, let thumbnailData = makeThumbnailData(imageData) {
                    let thumbnailFilename = "\(item.contentHash)-thumb.png"
                    let thumbnailURL = thumbnailsDirectory.appendingPathComponent(thumbnailFilename)
                    try thumbnailData.write(to: thumbnailURL, options: .atomic)
                    item.thumbnailFilename = thumbnailFilename
                    byteCount += Int64(thumbnailData.count)
                }
            }

            context.insert(ClipboardRecord(item: item, byteCount: byteCount))
        }
        try context.save()

        let backupURL = baseDirectory.appendingPathComponent("history.v1.backup.json")
        if !fileManager.fileExists(atPath: backupURL.path) {
            try? fileManager.moveItem(at: legacyHistoryFile, to: backupURL)
        }
    }

    private func removeOrphanedAssets(records: [ClipboardRecord]) {
        removeOrphanedFiles(
            in: assetsDirectory,
            retaining: Set(records.compactMap(\.assetFilename))
        )
        removeOrphanedFiles(
            in: thumbnailsDirectory,
            retaining: Set(records.compactMap(\.thumbnailFilename))
        )
    }

    private func removeOrphanedFiles(in directory: URL, retaining filenames: Set<String>) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for file in files where !filenames.contains(file.lastPathComponent) {
            try? fileManager.removeItem(at: file)
        }
    }

    private func complete<T>(
        _ result: Result<T, Error>,
        using completion: @escaping (Result<T, Error>) -> Void
    ) {
        DispatchQueue.main.async { completion(result) }
    }
}

@MainActor
final class ClipboardRepository: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []

    private let storage: ClipboardStorage?

    init(fileManager: FileManager = .default) {
        do {
            let storage = try ClipboardStorage(fileManager: fileManager)
            self.storage = storage
            storage.load { [weak self] result in
                switch result {
                case .success(let items):
                    self?.items = items
                case .failure(let error):
                    NSLog("Paste Lite: 无法读取历史记录：\(error.localizedDescription)")
                }
            }
        } catch {
            storage = nil
            NSLog("Paste Lite: 无法初始化历史存储：\(error.localizedDescription)")
        }
    }

    func record(_ capture: ClipboardCapture) {
        storage?.record(capture) { [weak self] result in
            switch result {
            case .success(let update):
                guard let self, let update else { return }
                self.items.removeAll {
                    $0.id == update.item.id || update.removedIDs.contains($0.id)
                }
                self.items.insert(update.item, at: 0)
            case .failure(let error):
                NSLog("Paste Lite: 无法保存剪贴板记录：\(error.localizedDescription)")
            }
        }
    }

    func markUsed(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var updated = items.remove(at: index)
        let usedAt = Date()
        updated.lastCopiedAt = usedAt
        items.insert(updated, at: 0)

        storage?.markUsed(id: item.id, at: usedAt) { error in
            if let error {
                NSLog("Paste Lite: 无法更新使用时间：\(error.localizedDescription)")
            }
        }
    }

    func assetURL(for item: ClipboardItem) -> URL? {
        storage?.assetURL(for: item)
    }

    func previewURL(for item: ClipboardItem) -> URL? {
        storage?.previewURL(for: item)
    }
}
