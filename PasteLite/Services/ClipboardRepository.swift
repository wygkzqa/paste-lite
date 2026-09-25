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
    var summaryText: String?
    var filePathsText: String?
    var imageFile: Bool?
    // UUID membership tokens remain queryable in SQLite without loading payloads.
    var groupIDsText: String?
    var customTitle: String?

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
        summaryText = item.textContent.map { String($0.drop(while: { $0.isWhitespace }).prefix(200)) } ?? ""
        filePathsText = item.filePaths.joined(separator: "\n")
        imageFile = item.hasImage
        customTitle = item.customTitle
    }

    var item: ClipboardItem { makeItem(summary: false) }

    func makeItem(summary: Bool) -> ClipboardItem {
        ClipboardItem(
            id: id,
            type: ClipboardContentType(rawValue: typeRawValue) ?? .text,
            textContent: summary ? summaryText : textContent,
            assetFilename: assetFilename,
            thumbnailFilename: thumbnailFilename,
            filePaths: (try? JSONDecoder().decode([String].self, from: filePathsData)) ?? [],
            sourceAppName: sourceAppName,
            sourceBundleID: sourceBundleID,
            contentHash: contentHash,
            createdAt: createdAt,
            lastCopiedAt: lastCopiedAt,
            groupIDs: groupIDsText?.split(separator: "\n").compactMap { UUID(uuidString: String($0)) },
            customTitle: customTitle
        )
    }
}

enum ClipboardGroupFilter: Hashable, Sendable {
    case all
    case ungrouped
    case group(UUID)
}

enum ClipboardTitleError: LocalizedError {
    case invalidTitle, missingRecord

    var errorDescription: String? {
        switch self {
        case .invalidTitle: L10n.tr("标题最多 100 个字符，且不能包含换行。")
        case .missingRecord: L10n.tr("记录已不存在，请关闭后重试。")
        }
    }
}

enum ClipboardEditError: LocalizedError {
    case emptyContent, tooLarge, invalidURL, duplicateContent, unsupportedContent

    var errorDescription: String? {
        switch self {
        case .emptyContent: L10n.tr("内容不能为空。")
        case .tooLarge: L10n.tr("内容超过设置中的文本大小限制。")
        case .invalidURL: L10n.tr("请输入完整链接，且不要包含空格或换行。")
        case .duplicateContent: L10n.tr("已有相同内容的记录，请修改内容后再保存。")
        case .unsupportedContent: L10n.tr("图片和文件仅支持编辑标题。")
        }
    }
}

enum ClipboardGroupError: LocalizedError {
    case invalidName, duplicateName, missingRecord

    var errorDescription: String? {
        switch self {
        case .invalidName: L10n.tr("分组名称须为 1–40 个字符。")
        case .duplicateName: L10n.tr("已有同名分组。")
        case .missingRecord: L10n.tr("记录或分组已不存在，请刷新后重试。")
        }
    }
}

enum ClipboardHistoryClearError: LocalizedError {
    case busy, failed, filesRemain

    var errorDescription: String? { L10n.tr(messageKey) }
    var messageKey: String {
        switch self {
        case .busy: "正在处理数据，请稍后再试。"
        case .failed: "无法清空历史记录，请检查存储权限后重试。"
        case .filesRemain: "历史记录已清空，但部分图片文件未能删除。请检查存储权限后再次清空。"
        }
    }
}

enum ClipboardDeleteError: LocalizedError {
    case failed, filesRemain

    var errorDescription: String? {
        switch self {
        case .failed: L10n.tr("无法删除记录，请重试。")
        case .filesRemain: L10n.tr("记录已删除，但部分图片文件未能清理。")
        }
    }
}

@Model
final class ClipboardGroupRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date

    init(name: String) {
        id = UUID()
        self.name = name
        createdAt = Date()
    }
}

struct PreparedCapture {
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

    static func prepare(_ capture: ClipboardCapture, limits: ClipboardLimits = .default) -> PreparedCapture? {
        var type = capture.type
        let payload: Data
        var imageData: Data?
        var thumbnailData: Data?

        switch type {
        case .text, .url:
            guard let text = capture.textContent, limits.allowsText(bytes: text.utf8.count) else { return nil }
            if type == .text { type = ClipboardContentType.forText(text) }
            payload = Data(text.utf8)

        case .file:
            payload = Data(capture.filePaths.joined(separator: "\u{0}").utf8)

        case .image:
            guard let sourceData = capture.imageData,
                  let pngData = normalizedPNGData(sourceData),
                  limits.allowsImage(bytes: pngData.count) else {
                return nil
            }
            payload = pngData
            imageData = pngData
            thumbnailData = makeThumbnailData(sourceData)
        }

        let contentHash = hash(type: type, data: payload)
        return PreparedCapture(
            type: type,
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

    private static func normalizedPNGData(_ data: Data) -> Data? {
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

    static func makeThumbnailData(_ data: Data) -> Data? {
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

    private static func hash(type: ClipboardContentType, data: Data) -> String {
        var typedData = Data(type.rawValue.utf8)
        typedData.append(0)
        typedData.append(data)
        return SHA256.hash(data: typedData).map { String(format: "%02x", $0) }.joined()
    }
}

struct ClipboardPage: Sendable {
    let items: [ClipboardItem]
    let total: Int
}

struct ClipboardQuery: Sendable, Equatable {
    var text = ""
    var type = ""
    var source = ""
    var matchingTypes: [String] = []
    var matchingSources: [String] = []
    var group: ClipboardGroupFilter = .all
}

private final class ClipboardQueryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw CancellationError() }
    }
}

private final class ClipboardStorage {
    private var cachedQuery: (query: ClipboardQuery, ids: [PersistentIdentifier])?
    private var limits: ClipboardLimits
    private let limitsURL: URL

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
        limitsURL = baseDirectory.appendingPathComponent("history-settings.json")
        if fileManager.fileExists(atPath: limitsURL.path) {
            limits = try JSONDecoder().decode(ClipboardLimits.self, from: Data(contentsOf: limitsURL))
            guard limits.isValid else { throw PasteImportError.storage }
        } else {
            limits = .default
        }
        assetsDirectory = baseDirectory.appendingPathComponent("Assets", isDirectory: true)
        thumbnailsDirectory = baseDirectory.appendingPathComponent("Thumbnails", isDirectory: true)
        legacyHistoryFile = baseDirectory.appendingPathComponent("history.json")

        try fileManager.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)

        let schema = Schema([ClipboardRecord.self, ClipboardGroupRecord.self])
        let configuration = ModelConfiguration(
            "PasteLite",
            schema: schema,
            url: baseDirectory.appendingPathComponent("history.store"),
            allowsSave: true,
            cloudKitDatabase: .none
        )
        container = try ModelContainer(for: schema, configurations: [configuration])
    }

    func load(completion: @escaping (Result<ClipboardLimits, Error>) -> Void) {
        queue.async { [self] in
            do {
                try migrateLegacyHistoryIfNeeded(context: makeContext())
                try prepareSummaries()
                if try cleanup(now: Date()) == 0 { try removeOrphanedAssets() }
                complete(.success(limits), using: completion)
            } catch { complete(.failure(error), using: completion) }
        }
    }

    private static let summaryProperties: [PartialKeyPath<ClipboardRecord>] = [
        \.id, \.typeRawValue, \.summaryText, \.filePathsData, \.sourceAppName,
        \.sourceBundleID, \.contentHash, \.createdAt, \.lastCopiedAt,
        \.assetFilename, \.thumbnailFilename, \.groupIDsText, \.customTitle
    ]

    private func prepareSummaries() throws {
        while true {
            let context = makeContext()
            var descriptor = FetchDescriptor<ClipboardRecord>(predicate: #Predicate { $0.summaryText == nil })
            descriptor.fetchLimit = 200
            let records = try context.fetch(descriptor)
            if records.isEmpty { return }
            for record in records {
                let item = record.item
                record.summaryText = item.textContent.map { String($0.drop(while: { $0.isWhitespace }).prefix(200)) } ?? ""
                record.filePathsText = item.filePaths.joined(separator: "\n")
                record.imageFile = item.hasImage
            }
            try context.save()
            cachedQuery = nil
        }
    }

    private func descriptor(for query: ClipboardQuery) -> FetchDescriptor<ClipboardRecord> {
        let text = query.text, type = query.type, source = query.source
        let allText = text.isEmpty, allTypes = type.isEmpty, allSources = source.isEmpty
        let images = type == "image", matchingTypes = query.matchingTypes, matchingSources = query.matchingSources
        let groupID: String
        if case .group(let id) = query.group { groupID = id.uuidString } else { groupID = "" }
        let allGroups = query.group == .all
        let ungrouped = query.group == .ungrouped
        // Build the same SQL predicate in small expressions: combining #Predicate
        // with evaluate requires macOS 14.4, and one large macro exceeds the type checker budget.
        let predicate = Predicate<ClipboardRecord> { record in
            typealias P = PredicateExpressions
            let needle = P.Value(text)
            let body = P.build_NilCoalesce(lhs: P.build_flatMap(P.build_KeyPath(root: record, keyPath: \.textContent)) {
                P.build_localizedStandardContains($0, needle)
            }, rhs: P.Value(false))
            let paths = P.build_NilCoalesce(lhs: P.build_flatMap(P.build_KeyPath(root: record, keyPath: \.filePathsText)) {
                P.build_localizedStandardContains($0, needle)
            }, rhs: P.Value(false))
            let title = P.build_NilCoalesce(lhs: P.build_flatMap(P.build_KeyPath(root: record, keyPath: \.customTitle)) {
                P.build_localizedStandardContains($0, needle)
            }, rhs: P.Value(false))
            let appName = P.build_KeyPath(root: record, keyPath: \.sourceAppName)
            let bundle = P.build_KeyPath(root: record, keyPath: \.sourceBundleID)
            let kind = P.build_KeyPath(root: record, keyPath: \.typeRawValue)
            let isImage = P.build_Equal(lhs: P.build_KeyPath(root: record, keyPath: \.imageFile), rhs: P.Value(true))
            let contentMatches = P.build_Disjunction(
                lhs: title, rhs: P.build_Disjunction(lhs: body, rhs: paths))
            let appMatches = P.build_Disjunction(
                lhs: P.build_localizedStandardContains(appName, needle), rhs: P.build_localizedStandardContains(bundle, needle))
            let imageMatches = P.build_Conjunction(lhs: isImage, rhs: P.Value(matchingTypes.contains("image")))
            let kindMatches = P.build_Disjunction(lhs: P.build_contains(P.Value(matchingTypes), kind), rhs: imageMatches)
            let aliases = P.build_Disjunction(lhs: kindMatches, rhs: P.build_contains(P.Value(matchingSources), appName))
            let contentOrApp = P.build_Disjunction(lhs: contentMatches, rhs: appMatches)
            let search = P.build_Disjunction(lhs: P.Value(allText), rhs: P.build_Disjunction(lhs: contentOrApp, rhs: aliases))
            let typeOrImage = P.build_Disjunction(lhs: P.build_Equal(lhs: kind, rhs: P.Value(type)),
                                                 rhs: P.build_Conjunction(lhs: P.Value(images), rhs: isImage))
            let typeFilter = P.build_Disjunction(lhs: P.Value(allTypes), rhs: typeOrImage)
            let sourceFilter = P.build_Disjunction(lhs: P.Value(allSources), rhs: P.build_Equal(lhs: appName, rhs: P.Value(source)))
            let memberships = P.build_KeyPath(root: record, keyPath: \.groupIDsText)
            let inGroup = P.build_NilCoalesce(lhs: P.build_flatMap(memberships) {
                P.build_contains($0, P.Value(groupID))
            }, rhs: P.Value(false))
            let noGroup = P.build_Disjunction(
                lhs: P.build_Equal(lhs: memberships, rhs: P.Value(nil as String?)),
                rhs: P.build_Equal(lhs: memberships, rhs: P.Value("" as String?)))
            let groupFilter = P.build_Disjunction(lhs: P.Value(allGroups), rhs: P.build_Disjunction(
                lhs: P.build_Conjunction(lhs: P.Value(ungrouped), rhs: noGroup),
                rhs: P.build_Conjunction(lhs: P.Value(!ungrouped), rhs: inGroup)))
            return P.build_Conjunction(lhs: groupFilter, rhs: P.build_Conjunction(lhs: search, rhs: P.build_Conjunction(lhs: typeFilter, rhs: sourceFilter)))
        }
        var descriptor = FetchDescriptor<ClipboardRecord>(predicate: predicate, sortBy: [
            SortDescriptor(\ClipboardRecord.lastCopiedAt, order: .reverse), SortDescriptor(\ClipboardRecord.contentHash)
        ])
        descriptor.includePendingChanges = false
        return descriptor
    }

    func query(_ query: ClipboardQuery, offset: Int, limit: Int, cancellation: ClipboardQueryCancellation, completion: @escaping (Result<ClipboardPage, Error>) -> Void) {
        queue.async { [self] in
            do {
                try cancellation.check()
                let context = makeContext()
                let allText = query.text.isEmpty
                var descriptor = descriptor(for: query)
                let total: Int
                if allText {
                    total = try context.fetchCount(descriptor)
                    descriptor.fetchOffset = offset
                } else {
                    // Cache only matching IDs. Pages and counts share one text scan; no bodies stay in memory.
                    if cachedQuery?.query != query {
                        cachedQuery = (query, try context.fetchIdentifiers(descriptor))
                    }
                    let ids = cachedQuery!.ids
                    total = ids.count
                    let pageIDs = Array(ids.dropFirst(offset).prefix(limit))
                    if pageIDs.isEmpty {
                        complete(.success(ClipboardPage(items: [], total: total)), using: completion)
                        return
                    }
                    descriptor.predicate = #Predicate { pageIDs.contains($0.persistentModelID) }
                }
                try cancellation.check()
                descriptor.fetchLimit = limit
                descriptor.propertiesToFetch = Self.summaryProperties
                let items = try context.fetch(descriptor).map { $0.makeItem(summary: true) }
                complete(.success(ClipboardPage(items: items, total: total)), using: completion)
            } catch { complete(.failure(error), using: completion) }
        }
    }

    func groups(completion: @escaping (Result<[ClipboardGroup], Error>) -> Void) {
        queue.async { [self] in
            do {
                let descriptor = FetchDescriptor<ClipboardGroupRecord>(sortBy: [SortDescriptor(\.createdAt)])
                let groups = try makeContext().fetch(descriptor).map { ClipboardGroup(id: $0.id, name: $0.name) }
                complete(.success(groups), using: completion)
            } catch { complete(.failure(error), using: completion) }
        }
    }

    func saveGroup(id: UUID?, name: String, completion: @escaping (Result<ClipboardGroup, Error>) -> Void) {
        queue.async { [self] in
            do {
                let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.count <= 40 else { throw ClipboardGroupError.invalidName }
                let context = makeContext()
                let groups = try context.fetch(FetchDescriptor<ClipboardGroupRecord>())
                guard !groups.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
                    throw ClipboardGroupError.duplicateName
                }
                let record: ClipboardGroupRecord
                if let id {
                    guard let existing = groups.first(where: { $0.id == id }) else { throw ClipboardGroupError.missingRecord }
                    record = existing
                    record.name = name
                } else {
                    record = ClipboardGroupRecord(name: name)
                    context.insert(record)
                }
                try context.save()
                complete(.success(ClipboardGroup(id: record.id, name: record.name)), using: completion)
            } catch { complete(.failure(error), using: completion) }
        }
    }

    func deleteGroup(id: UUID, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            do {
                let context = makeContext()
                let token = id.uuidString
                let descriptor = FetchDescriptor<ClipboardGroupRecord>(predicate: #Predicate { $0.id == id })
                guard let group = try context.fetch(descriptor).first else { throw ClipboardGroupError.missingRecord }
                var records = FetchDescriptor<ClipboardRecord>(predicate: #Predicate { $0.groupIDsText?.contains(token) == true })
                records.propertiesToFetch = [\.groupIDsText]
                try context.enumerate(records, batchSize: 200, allowEscapingMutations: true) { record in
                    record.groupIDsText = record.groupIDsText?.split(separator: "\n").filter { $0 != token }.joined(separator: "\n")
                }
                context.delete(group)
                try context.save()
                cachedQuery = nil
                complete(.success(()), using: completion)
            } catch { complete(.failure(error), using: completion) }
        }
    }

    func setGroups(_ groupIDs: Set<UUID>, for itemID: UUID, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            do {
                let context = makeContext()
                let descriptor = FetchDescriptor<ClipboardRecord>(predicate: #Predicate { $0.id == itemID })
                guard let record = try context.fetch(descriptor).first else { throw ClipboardGroupError.missingRecord }
                let validIDs = Set(try context.fetch(FetchDescriptor<ClipboardGroupRecord>()).map(\.id))
                guard groupIDs.isSubset(of: validIDs) else { throw ClipboardGroupError.missingRecord }
                record.groupIDsText = groupIDs.map(\.uuidString).sorted().joined(separator: "\n")
                try context.save()
                cachedQuery = nil
                complete(.success(()), using: completion)
            } catch { complete(.failure(error), using: completion) }
        }
    }

    func sources(completion: @escaping (Result<[String], Error>) -> Void) {
        queue.async { [self] in
            do {
                let context = makeContext()
                var descriptor = FetchDescriptor<ClipboardRecord>()
                descriptor.propertiesToFetch = [\.sourceAppName]
                var names = Set<String>()
                try context.enumerate(descriptor, batchSize: 500) { record in
                    if !record.sourceAppName.isEmpty { names.insert(record.sourceAppName) }
                }
                complete(.success(names.sorted()), using: completion)
            } catch { complete(.failure(error), using: completion) }
        }
    }

    func setGroup(_ groupID: UUID, for itemIDs: Set<UUID>, included: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            let context = makeContext()
            do {
                guard try context.fetchCount(FetchDescriptor<ClipboardGroupRecord>(predicate: #Predicate { $0.id == groupID })) == 1 else {
                    throw ClipboardGroupError.missingRecord
                }
                let ids = Array(itemIDs)
                for start in stride(from: 0, to: ids.count, by: 200) {
                    let batch = Array(ids[start..<min(start + 200, ids.count)])
                    var descriptor = FetchDescriptor<ClipboardRecord>(predicate: #Predicate { batch.contains($0.id) })
                    descriptor.propertiesToFetch = [\.id, \.groupIDsText]
                    let records = try context.fetch(descriptor)
                    guard records.count == batch.count else { throw ClipboardGroupError.missingRecord }
                    for record in records {
                        var groups = Set(record.groupIDsText?.split(separator: "\n").map(String.init) ?? [])
                        if included { groups.insert(groupID.uuidString) }
                        else { groups.remove(groupID.uuidString) }
                        record.groupIDsText = groups.sorted().joined(separator: "\n")
                    }
                }
                try context.save()
                cachedQuery = nil
                complete(.success(()), using: completion)
            } catch {
                context.rollback()
                complete(.failure(error), using: completion)
            }
        }
    }

    func selection(for query: ClipboardQuery, cancellation: ClipboardQueryCancellation,
                   completion: @escaping (Result<[UUID: Set<UUID>], Error>) -> Void) {
        queue.async { [self] in
            do {
                try cancellation.check()
                let context = makeContext()
                var descriptor = descriptor(for: query)
                descriptor.propertiesToFetch = [\.id, \.groupIDsText]
                var selection: [UUID: Set<UUID>] = [:]
                try context.enumerate(descriptor, batchSize: 500) { record in
                    try cancellation.check()
                    selection[record.id] = Set(record.groupIDsText?.split(separator: "\n").compactMap { UUID(uuidString: String($0)) } ?? [])
                }
                complete(.success(selection), using: completion)
            } catch { complete(.failure(error), using: completion) }
        }
    }

    func deleteItems(_ itemIDs: Set<UUID>, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            let context = makeContext()
            var assets = Set<String>(), thumbnails = Set<String>()
            do {
                let ids = Array(itemIDs)
                for start in stride(from: 0, to: ids.count, by: 200) {
                    let batch = Array(ids[start..<min(start + 200, ids.count)])
                    var descriptor = FetchDescriptor<ClipboardRecord>(predicate: #Predicate { batch.contains($0.id) })
                    descriptor.propertiesToFetch = [\.id, \.assetFilename, \.thumbnailFilename]
                    for record in try context.fetch(descriptor) {
                        if let name = record.assetFilename { assets.insert(name) }
                        if let name = record.thumbnailFilename { thumbnails.insert(name) }
                        context.delete(record)
                    }
                }
                // A leftover migration input must not resurrect deleted history on an empty-store restart.
                if fileManager.fileExists(atPath: legacyHistoryFile.path) { try fileManager.removeItem(at: legacyHistoryFile) }
                try context.save()
                cachedQuery = nil
            } catch {
                context.rollback()
                complete(.failure(ClipboardDeleteError.failed), using: completion)
                return
            }
            do {
                if !assets.isEmpty || !thumbnails.isEmpty {
                    var remaining = FetchDescriptor<ClipboardRecord>()
                    remaining.propertiesToFetch = [\.assetFilename, \.thumbnailFilename]
                    try context.enumerate(remaining, batchSize: 500) { record in
                        if let name = record.assetFilename { assets.remove(name) }
                        if let name = record.thumbnailFilename { thumbnails.remove(name) }
                    }
                }
                var filesRemain = false
                for (directory, filenames) in [(assetsDirectory, assets), (thumbnailsDirectory, thumbnails)] {
                    for name in filenames {
                        let url = directory.appendingPathComponent(name).standardizedFileURL
                        guard url.deletingLastPathComponent() == directory.standardizedFileURL else { filesRemain = true; continue }
                        if fileManager.fileExists(atPath: url.path) {
                            do { try fileManager.removeItem(at: url) }
                            catch { filesRemain = true }
                        }
                    }
                }
                complete(filesRemain ? .failure(ClipboardDeleteError.filesRemain) : .success(()), using: completion)
            } catch { complete(.failure(ClipboardDeleteError.filesRemain), using: completion) }
        }
    }

    func item(id: UUID, completion: @escaping (Result<ClipboardItem?, Error>) -> Void) {
        queue.async { [self] in
            do {
                let context = makeContext()
                let descriptor = FetchDescriptor<ClipboardRecord>(predicate: #Predicate { $0.id == id })
                complete(.success(try context.fetch(descriptor).first?.item), using: completion)
            } catch { complete(.failure(error), using: completion) }
        }
    }

    func updateLimits(_ updated: ClipboardLimits, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            do {
                guard updated.isValid else { throw PasteImportError.storage }
                try JSONEncoder().encode(updated).write(to: limitsURL, options: .atomic)
                limits = updated
                complete(.success(()), using: completion)
            } catch { complete(.failure(error), using: completion) }
        }
    }

    func cleanHistory(now: Date, completion: @escaping (Result<Int, Error>) -> Void) {
        queue.async { [self] in
            do { complete(.success(try cleanup(now: now)), using: completion) }
            catch { complete(.failure(error), using: completion) }
        }
    }

    func clearHistory(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            let context = makeContext()
            do {
                // Remove old migration input before emptying the database, so it cannot return on restart.
                for file in [legacyHistoryFile, baseDirectory.appendingPathComponent("history.v1.backup.json")] {
                    if fileManager.fileExists(atPath: file.path) { try fileManager.removeItem(at: file) }
                }
                try context.delete(model: ClipboardRecord.self)
                try context.save()
                cachedQuery = nil
            } catch {
                context.rollback()
                complete(.failure(ClipboardHistoryClearError.failed), using: completion)
                return
            }
            var filesRemain = false
            for directory in [assetsDirectory, thumbnailsDirectory] {
                do {
                    let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    for file in files {
                        do { try fileManager.removeItem(at: file) }
                        catch { filesRemain = true }
                    }
                } catch { filesRemain = true }
            }
            complete(filesRemain ? .failure(ClipboardHistoryClearError.filesRemain) : .success(()), using: completion)
        }
    }

    func record(
        _ capture: ClipboardCapture,
        completion: @escaping (Result<ClipboardItem?, Error>) -> Void
    ) {
        queue.async { [self] in
            do {
                guard let prepared = PreparedCapture.prepare(capture, limits: limits) else {
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
                cachedQuery = nil
                complete(
                    .success(record.makeItem(summary: true)),
                    using: completion
                )
            } catch {
                complete(.failure(error), using: completion)
            }
        }
    }

    func editItem(id: UUID, title: String, textContent: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            let context = makeContext()
            do {
                let descriptor = FetchDescriptor<ClipboardRecord>(predicate: #Predicate { $0.id == id })
                guard let record = try context.fetch(descriptor).first else { throw ClipboardTitleError.missingRecord }
                let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                // Imported titles may be longer; editing only the body must preserve them.
                guard title == record.customTitle || (title.count <= 100 && title.rangeOfCharacter(from: .newlines) == nil) else {
                    throw ClipboardTitleError.invalidTitle
                }
                if let textContent, textContent != record.textContent {
                    guard let type = ClipboardContentType(rawValue: record.typeRawValue), type == .text || type == .url else {
                        throw ClipboardEditError.unsupportedContent
                    }
                    guard !textContent.isEmpty else { throw ClipboardEditError.emptyContent }
                    if type == .url {
                        guard let url = URL(string: textContent), url.scheme?.isEmpty == false,
                              textContent.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
                            throw ClipboardEditError.invalidURL
                        }
                    }
                    let capture = ClipboardCapture(type: type, textContent: textContent, imageData: nil, filePaths: [],
                        sourceAppName: record.sourceAppName, sourceBundleID: record.sourceBundleID, capturedAt: record.lastCopiedAt)
                    guard let prepared = PreparedCapture.prepare(capture, limits: limits) else { throw ClipboardEditError.tooLarge }
                    let hash = prepared.contentHash
                    let duplicate = FetchDescriptor<ClipboardRecord>(predicate: #Predicate { $0.contentHash == hash && $0.id != id })
                    guard try context.fetchCount(duplicate) == 0 else { throw ClipboardEditError.duplicateContent }
                    record.textContent = textContent
                    record.typeRawValue = prepared.type.rawValue
                    record.summaryText = String(textContent.drop(while: { $0.isWhitespace }).prefix(200))
                    record.contentHash = hash
                    record.byteCount = prepared.byteCount
                }
                record.customTitle = title.isEmpty ? nil : title
                try context.save()
                cachedQuery = nil
                complete(.success(()), using: completion)
            } catch {
                context.rollback()
                complete(.failure(error), using: completion)
            }
        }
    }

    func previewImport(_ batch: PasteImportBatch, completion: @escaping (Result<PasteImportPreview, Error>) -> Void) {
        queue.async { [self] in
            do {
                let context = makeContext()
                var descriptor = FetchDescriptor<ClipboardRecord>()
                descriptor.propertiesToFetch = [\.contentHash, \.byteCount, \.groupIDsText, \.customTitle]
                let records = try context.fetch(descriptor)
                let groups = try context.fetch(FetchDescriptor<ClipboardGroupRecord>())
                complete(.success(try importPreview(batch, records: records, groups: groups)), using: completion)
            } catch { complete(.failure(error), using: completion) }
        }
    }

    private func importPreview(_ batch: PasteImportBatch, records: [ClipboardRecord], groups: [ClipboardGroupRecord]) throws -> PasteImportPreview {
        guard batch.limits.maxTextMB == limits.maxTextMB, batch.limits.maxImageMB == limits.maxImageMB else {
            throw PasteImportError.settingsChanged
        }
        let hashes = Set(records.map(\.contentHash))
        let entries = batch.entries.filter { !hashes.contains($0.item.contentHash) }
        var preview = PasteImportPreview(
            entries: entries, existingHashes: hashes,
            existingBytes: records.reduce(0) { $0 + $1.byteCount }, limits: limits,
            duplicates: batch.duplicates + batch.entries.count - entries.count
        )
        let importedTitles = Dictionary(uniqueKeysWithValues: batch.entries.compactMap { entry in
            entry.item.customTitle.map { (entry.item.contentHash, $0) }
        })
        for record in records where importedTitles[record.contentHash] != nil {
            preview.existingTitles[record.contentHash] = record.customTitle ?? ""
            if record.customTitle == nil || record.customTitle?.isEmpty == true {
                preview.titleUpdates[record.contentHash] = importedTitles[record.contentHash]
            }
        }
        preview.existingGroups = groups.map { ClipboardGroup(id: $0.id, name: $0.name) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        var destinationGroups = preview.existingGroups
        for source in batch.groups {
            let group: ClipboardGroup
            if let existing = destinationGroups.first(where: { $0.name.localizedCaseInsensitiveCompare(source.name) == .orderedSame }) {
                group = existing
            } else {
                // Imported names are preserved in full, even above the manual name editor's limit.
                group = ClipboardGroup(id: UUID(), name: source.name)
                destinationGroups.append(group)
                preview.groupsToCreate.append(group)
            }
            preview.groupIDsBySource[source.id] = group.id
        }
        let groupedHashes = Set(batch.entries.filter { !$0.groupIDs.isEmpty }.map { $0.item.contentHash })
        for record in records where groupedHashes.contains(record.contentHash) {
            preview.existingMemberships[record.contentHash] = Set(
                record.groupIDsText?.split(separator: "\n").compactMap { UUID(uuidString: String($0)) } ?? []
            )
        }
        for entry in batch.entries {
            guard let existing = preview.existingMemberships[entry.item.contentHash] else { continue }
            let imported = Set(entry.groupIDs.compactMap { preview.groupIDsBySource[$0] })
            if !imported.isSubset(of: existing) {
                preview.groupUpdates[entry.item.contentHash] = existing.union(imported)
            }
        }
        return preview
    }

    func importBatch(
        _ batch: PasteImportBatch, preview: PasteImportPreview, expand: Bool,
        completion: @escaping (Result<(PasteImportResult, ClipboardLimits), Error>) -> Void
    ) {
        queue.async { [self] in
            let context = makeContext()
            let previousLimits = limits
            var createdFiles: [URL] = []
            var changedLimits = false
            do {
                var descriptor = FetchDescriptor<ClipboardRecord>()
                descriptor.propertiesToFetch = [\.contentHash, \.byteCount, \.groupIDsText, \.customTitle]
                let records = try context.fetch(descriptor)
                let groups = try context.fetch(FetchDescriptor<ClipboardGroupRecord>())
                let current = try importPreview(batch, records: records, groups: groups)
                guard current.existingHashes == preview.existingHashes,
                      current.existingBytes == preview.existingBytes,
                      current.limits == preview.limits,
                      current.existingGroups == preview.existingGroups,
                      current.existingMemberships == preview.existingMemberships,
                      current.existingTitles == preview.existingTitles else {
                    throw PasteImportError.stalePreview(current)
                }
                let selected = current.selectedEntries(expand: expand)
                let addedBytes = selected.reduce(Int64(0)) { $0 + $1.byteCount }
                try PasteImportService.checkDiskSpace(at: baseDirectory, required: addedBytes + 10 * 1_024 * 1_024)
                for group in current.groupsToCreate {
                    let record = ClipboardGroupRecord(name: group.name)
                    record.id = group.id
                    context.insert(record)
                }
                for record in records {
                    if let title = current.titleUpdates[record.contentHash] {
                        record.customTitle = title
                    }
                    if let memberships = current.groupUpdates[record.contentHash] {
                        record.groupIDsText = memberships.map(\.uuidString).sorted().joined(separator: "\n")
                    }
                }
                for entry in selected {
                    for (filename, directory) in [(entry.item.assetFilename, assetsDirectory), (entry.item.thumbnailFilename, thumbnailsDirectory)] {
                        guard let filename else { continue }
                        let destination = directory.appendingPathComponent(filename)
                        if !fileManager.fileExists(atPath: destination.path) {
                            createdFiles.append(destination)
                            try fileManager.copyItem(at: batch.directory.appendingPathComponent(filename), to: destination)
                        }
                    }
                    let record = ClipboardRecord(item: entry.item, byteCount: entry.byteCount)
                    let memberships = Set(entry.groupIDs.compactMap { current.groupIDsBySource[$0] })
                    if !memberships.isEmpty {
                        record.groupIDsText = memberships.map(\.uuidString).sorted().joined(separator: "\n")
                    }
                    context.insert(record)
                }
                if expand && current.needsExpansion {
                    var expanded = limits
                    expanded.itemCount = current.requiredCount
                    // Persist before committing: a crash must not let startup trim new records with the old limit.
                    try JSONEncoder().encode(expanded).write(to: limitsURL, options: .atomic)
                    limits = expanded
                    changedLimits = true
                }
                try context.save()
                cachedQuery = nil
                let result = PasteImportResult(
                    added: selected.count, duplicates: current.duplicates, skipped: batch.skipped,
                    capacitySkipped: current.entries.count - selected.count,
                    groupsAdded: current.groupsToCreate.count, recordsUpdated: current.groupUpdates.count,
                    titlesUpdated: current.titleUpdates.count
                )
                complete(.success((result, limits)), using: completion)
            } catch {
                context.rollback()
                createdFiles.forEach { try? fileManager.removeItem(at: $0) }
                if changedLimits {
                    // Retaining a larger limit is safe if restoring this tiny settings file fails.
                    if (try? JSONEncoder().encode(previousLimits).write(to: limitsURL, options: .atomic)) != nil {
                        limits = previousLimits
                    }
                }
                complete(.failure(error is PasteImportError ? error : PasteImportError.storage), using: completion)
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
                    cachedQuery = nil
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
            return thumbnailsDirectory.appendingPathComponent(filename)
        }
        return assetURL(for: item)
    }

    private func makeContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
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

    private func cleanup(now: Date) throws -> Int {
        guard limits.retentionDays > 0 || limits.itemCount > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(limits.retentionDays) * 86_400)
        var removed = 0
        for expiredOnly in [true, false] {
            if expiredOnly && limits.retentionDays == 0 { continue }
            if !expiredOnly && limits.itemCount == 0 { continue }
            while true {
                let context = makeContext()
                let predicate = #Predicate<ClipboardRecord> { !expiredOnly || $0.createdAt < cutoff }
                var descriptor = FetchDescriptor<ClipboardRecord>(predicate: predicate, sortBy: [
                    SortDescriptor(\ClipboardRecord.createdAt, order: .reverse), SortDescriptor(\ClipboardRecord.contentHash)
                ])
                descriptor.fetchOffset = expiredOnly ? 0 : limits.itemCount
                descriptor.fetchLimit = 200
                descriptor.propertiesToFetch = [\.id]
                let records = try context.fetch(descriptor)
                if records.isEmpty { break }
                records.forEach { context.delete($0) }
                try context.save()
                cachedQuery = nil
                removed += records.count
            }
        }
        if removed > 0 { try removeOrphanedAssets() }
        return removed
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

                if let imageData, let thumbnailData = PreparedCapture.makeThumbnailData(imageData) {
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
        cachedQuery = nil

        let backupURL = baseDirectory.appendingPathComponent("history.v1.backup.json")
        if !fileManager.fileExists(atPath: backupURL.path) {
            try? fileManager.moveItem(at: legacyHistoryFile, to: backupURL)
        }
    }

    private func removeOrphanedAssets() throws {
        let context = makeContext()
        var descriptor = FetchDescriptor<ClipboardRecord>()
        descriptor.propertiesToFetch = [\.assetFilename, \.thumbnailFilename]
        var assets = Set<String>(), thumbnails = Set<String>()
        try context.enumerate(descriptor, batchSize: 500) { record in
            if let name = record.assetFilename { assets.insert(name) }
            if let name = record.thumbnailFilename { thumbnails.insert(name) }
        }
        removeOrphanedFiles(in: assetsDirectory, retaining: assets)
        removeOrphanedFiles(in: thumbnailsDirectory, retaining: thumbnails)
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
    nonisolated static let pageSize = 200
    @Published private(set) var items: [ClipboardItem] = []
    @Published private(set) var totalCount = 0
    @Published private(set) var sourceApps: [String] = []
    @Published private(set) var groups: [ClipboardGroup] = []
    @Published private(set) var revision = 0
    @Published private(set) var limits = ClipboardLimits.default
    @Published private(set) var isReady = false
    @Published private(set) var isSavingLimits = false
    @Published private(set) var isClearingHistory = false
    @Published private(set) var isDeletingItems = false
    @Published private(set) var errorMessage: String?
    private let storage: ClipboardStorage?
    private var cleanupTimer: Timer?
    private var lastCleanup = Date()
    private var cleaning = false

    init(fileManager: FileManager = .default) {
        do {
            let storage = try ClipboardStorage(fileManager: fileManager)
            self.storage = storage
            storage.load { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let limits):
                    self.limits = limits
                    self.isReady = true
                    self.lastCleanup = Date()
                    self.scheduleCleanup()
                    Task { await self.reload() }
                case .failure:
                    self.errorMessage = "无法读取历史记录，请重试。"
                }
            }
        } catch {
            storage = nil
            errorMessage = "无法读取历史记录，请重试。"
        }
    }

    deinit { cleanupTimer?.invalidate() }

    private func scheduleCleanup() {
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        guard limits.cleanupIntervalHours > 0 else { return }
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.checkCleanup() }
        }
        cleanupTimer?.tolerance = 10
    }

    func checkCleanup(now: Date = Date()) async {
        guard !cleaning, limits.cleanupIntervalHours > 0,
              now.timeIntervalSince(lastCleanup) >= Double(limits.cleanupIntervalHours) * 3_600 else { return }
        cleaning = true
        defer { cleaning = false }
        do {
            _ = try await cleanHistory(now: now)
            lastCleanup = now
        } catch { errorMessage = "无法清理历史记录，请重试。" }
    }

    @discardableResult
    func cleanHistory(now: Date = Date()) async throws -> Int {
        guard !isClearingHistory else { return 0 }
        guard let storage else { throw PasteImportError.storage }
        let count: Int = try await withCheckedThrowingContinuation { continuation in
            storage.cleanHistory(now: now) { continuation.resume(with: $0) }
        }
        if count > 0 { await reload() }
        return count
    }

    func clearHistory() async throws {
        guard let storage, isReady, !isSavingLimits, !isClearingHistory, !isDeletingItems else { throw ClipboardHistoryClearError.busy }
        isClearingHistory = true
        defer { isClearingHistory = false }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                storage.clearHistory { continuation.resume(with: $0) }
            }
        } catch {
            // The database may be cleared even when deleting an image file fails.
            await reload()
            throw error
        }
        await reload()
    }

    func updateLimits(_ limits: ClipboardLimits) async throws {
        guard let storage, !isSavingLimits, !isClearingHistory else { throw PasteImportError.storage }
        isSavingLimits = true
        defer { isSavingLimits = false }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            storage.updateLimits(limits) { continuation.resume(with: $0) }
        }
        self.limits = limits
        scheduleCleanup()
    }

    func query(_ query: ClipboardQuery = ClipboardQuery(), offset: Int = 0, limit: Int = ClipboardRepository.pageSize) async throws -> ClipboardPage {
        guard let storage else { throw PasteImportError.storage }
        try Task.checkCancellation()
        let cancellation = ClipboardQueryCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                storage.query(query, offset: offset, limit: limit, cancellation: cancellation) { continuation.resume(with: $0) }
            }
        } onCancel: { cancellation.cancel() }
    }

    func item(id: UUID) async throws -> ClipboardItem? {
        guard let storage else { throw PasteImportError.storage }
        return try await withCheckedThrowingContinuation { continuation in
            storage.item(id: id) { continuation.resume(with: $0) }
        }
    }

    func selection(for query: ClipboardQuery) async throws -> [UUID: Set<UUID>] {
        guard let storage else { throw PasteImportError.storage }
        try Task.checkCancellation()
        let cancellation = ClipboardQueryCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                storage.selection(for: query, cancellation: cancellation) { continuation.resume(with: $0) }
            }
        } onCancel: { cancellation.cancel() }
    }

    @discardableResult
    func saveGroup(id: UUID? = nil, name: String) async throws -> ClipboardGroup {
        guard let storage else { throw PasteImportError.storage }
        let group: ClipboardGroup = try await withCheckedThrowingContinuation { continuation in
            storage.saveGroup(id: id, name: name) { continuation.resume(with: $0) }
        }
        await reload(refreshSources: false)
        return group
    }

    func renameTitle(id: UUID, title: String) async throws {
        try await editItem(id: id, title: title, textContent: nil)
    }

    func editItem(id: UUID, title: String, textContent: String?) async throws {
        guard let storage, isReady, !isClearingHistory else { throw ClipboardHistoryClearError.busy }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            storage.editItem(id: id, title: title, textContent: textContent) { continuation.resume(with: $0) }
        }
        await reload(refreshSources: false)
    }

    func deleteGroup(id: UUID) async throws {
        guard let storage else { throw PasteImportError.storage }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            storage.deleteGroup(id: id) { continuation.resume(with: $0) }
        }
        await reload(refreshSources: false)
    }

    func setGroups(_ groupIDs: Set<UUID>, for itemID: UUID) async throws {
        guard let storage else { throw PasteImportError.storage }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            storage.setGroups(groupIDs, for: itemID) { continuation.resume(with: $0) }
        }
        await reload(refreshSources: false)
    }

    func setGroup(_ groupID: UUID, for itemIDs: Set<UUID>, included: Bool) async throws {
        guard !itemIDs.isEmpty else { return }
        guard let storage, isReady, !isClearingHistory, !isDeletingItems else { throw ClipboardHistoryClearError.busy }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            storage.setGroup(groupID, for: itemIDs, included: included) { continuation.resume(with: $0) }
        }
        await reload(refreshSources: false)
    }

    func deleteItems(_ itemIDs: Set<UUID>) async throws {
        guard !itemIDs.isEmpty else { return }
        guard let storage, isReady, !isClearingHistory, !isDeletingItems, !isSavingLimits else { throw ClipboardHistoryClearError.busy }
        isDeletingItems = true
        defer { isDeletingItems = false }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                storage.deleteItems(itemIDs) { continuation.resume(with: $0) }
            }
        } catch {
            await reload()
            throw error
        }
        await reload()
    }

    func reload(refreshSources: Bool = true) async {
        do {
            let page = try await query()
            items = page.items
            totalCount = page.total
            if let storage {
                groups = try await withCheckedThrowingContinuation { continuation in
                    storage.groups { continuation.resume(with: $0) }
                }
            }
            if refreshSources, let storage {
                sourceApps = try await withCheckedThrowingContinuation { continuation in
                    storage.sources { continuation.resume(with: $0) }
                }
            }
            errorMessage = nil
            revision += 1
        } catch { errorMessage = "无法读取历史记录，请重试。" }
    }

    func record(_ capture: ClipboardCapture) {
        guard !isClearingHistory else { return }
        storage?.record(capture) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let item):
                guard let item else { return }
                if !item.sourceAppName.isEmpty, !self.sourceApps.contains(item.sourceAppName) {
                    self.sourceApps = (self.sourceApps + [item.sourceAppName]).sorted()
                }
                Task { await self.reload(refreshSources: false) }
            case .failure:
                self.errorMessage = "无法保存剪贴板记录。"
            }
        }
    }

    func previewImport(_ batch: PasteImportBatch) async throws -> PasteImportPreview {
        guard let storage else { throw PasteImportError.storage }
        return try await withCheckedThrowingContinuation { continuation in
            storage.previewImport(batch) { continuation.resume(with: $0) }
        }
    }

    func importBatch(_ batch: PasteImportBatch, preview: PasteImportPreview, expand: Bool) async throws -> PasteImportResult {
        guard let storage, !isSavingLimits, !isClearingHistory, !isDeletingItems else { throw PasteImportError.storage }
        isSavingLimits = true
        defer { isSavingLimits = false }
        let (result, limits): (PasteImportResult, ClipboardLimits) = try await withCheckedThrowingContinuation { continuation in
            storage.importBatch(batch, preview: preview, expand: expand) { continuation.resume(with: $0) }
        }
        self.limits = limits
        await reload()
        return result
    }

    func markUsed(_ item: ClipboardItem) {
        storage?.markUsed(id: item.id, at: Date()) { [weak self] error in
            guard let self else { return }
            if error != nil { self.errorMessage = "无法保存剪贴板记录。" }
            else { Task { await self.reload(refreshSources: false) } }
        }
    }

    func assetURL(for item: ClipboardItem) -> URL? { storage?.assetURL(for: item) }
    func previewURL(for item: ClipboardItem) -> URL? { storage?.previewURL(for: item) }
}
