import Foundation
import SwiftData

// Frozen schema immediately before groups: verify the additive store migration.
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
        summaryText = item.textContent.map { String($0.prefix(200)) } ?? ""
        filePathsText = item.filePaths.joined(separator: "\n")
        imageFile = item.hasImage
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


@main
struct PreGroupHistoryFixture {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("PasteLite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let schema = Schema([ClipboardRecord.self])
        let configuration = ModelConfiguration("PasteLite", schema: schema, url: root.appendingPathComponent("history.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        for index in 0..<1_205 {
            let text = "Legacy record \(index) " + (index == 1_204 ? String(repeating: "完整正文", count: 1_000) + "legacy-tail-needle" : "Sample")
            let item = ClipboardItem(id: UUID(), type: .text, textContent: text, assetFilename: nil,
                thumbnailFilename: nil, filePaths: [], sourceAppName: "Legacy Fixture", sourceBundleID: "test.legacy",
                contentHash: "legacy-\(index)", createdAt: Date(timeIntervalSince1970: Double(index)),
                lastCopiedAt: Date(timeIntervalSince1970: Double(index)))
            context.insert(ClipboardRecord(item: item, byteCount: Int64(text.utf8.count)))
        }
        try context.save()
        try Data("{\"itemCount\":1,\"storageBytes\":1}".utf8).write(to: root.appendingPathComponent("limits.json"))
    }
}
