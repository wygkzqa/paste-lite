import Foundation
import SwiftData

// Frozen schema before custom titles; keep independent of the current storage model.
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
            groupIDs: groupIDsText?.split(separator: "\n").compactMap { UUID(uuidString: String($0)) }
        )
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

@main
struct PreTitleHistoryFixture {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("PasteLite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let schema = Schema([ClipboardRecord.self, ClipboardGroupRecord.self])
        let configuration = ModelConfiguration("PasteLite", schema: schema, url: root.appendingPathComponent("history.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let group = ClipboardGroupRecord(name: "Existing group")
        context.insert(group)
        for index in 0..<205 {
            let item = ClipboardItem(id: UUID(), type: .text, textContent: "Legacy title fixture \(index)",
                assetFilename: nil, thumbnailFilename: nil, filePaths: [], sourceAppName: "Fixture", sourceBundleID: "example.fixture",
                contentHash: "legacy-\(index)", createdAt: Date(timeIntervalSince1970: Double(index)), lastCopiedAt: Date(timeIntervalSince1970: Double(index)))
            let record = ClipboardRecord(item: item, byteCount: 32)
            record.groupIDsText = group.id.uuidString
            context.insert(record)
        }
        try context.save()
    }
}
