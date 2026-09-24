import Foundation

struct ClipboardLimits: Codable, Equatable, Sendable {
    var itemCount = 0
    var retentionDays = 0
    var cleanupIntervalHours = 0
    var maxTextMB = 4
    var maxImageMB = 100
    static let `default` = ClipboardLimits()

    var isValid: Bool {
        [itemCount, retentionDays, cleanupIntervalHours, maxTextMB, maxImageMB]
            .allSatisfy { $0 >= 0 && $0 <= Int(UInt32.max) }
    }

    func allowsText(bytes: Int) -> Bool {
        maxTextMB == 0 || Int64(bytes) <= Int64(maxTextMB) * 1_024 * 1_024
    }

    func allowsImage(bytes: Int) -> Bool {
        maxImageMB == 0 || Int64(bytes) <= Int64(maxImageMB) * 1_024 * 1_024
    }
}

struct PasteImportEntry: Sendable {
    var item: ClipboardItem
    let byteCount: Int64
    var groupIDs: Set<Int64> = []
}

/// Source database keys are mapped to local group UUIDs during import.
struct PasteImportGroup: Sendable {
    let id: Int64
    let name: String
}

/// Owns only this scan's temporary resources. Keeping the batch alive keeps its files alive.
final class PasteImportBatch: @unchecked Sendable {
    let directory: URL
    let entries: [PasteImportEntry]
    let total: Int
    let duplicates: Int
    let skipped: [String: Int]
    let limits: ClipboardLimits
    let groups: [PasteImportGroup]

    init(directory: URL, entries: [PasteImportEntry], total: Int, duplicates: Int, skipped: [String: Int], limits: ClipboardLimits = .default, groups: [PasteImportGroup] = []) {
        self.directory = directory
        self.entries = entries
        self.total = total
        self.duplicates = duplicates
        self.skipped = skipped
        self.limits = limits
        self.groups = groups
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

struct PasteImportPreview: Sendable {
    let entries: [PasteImportEntry]
    let existingHashes: Set<String>
    let existingBytes: Int64
    let limits: ClipboardLimits
    let duplicates: Int
    var groupsToCreate: [ClipboardGroup] = []
    var groupIDsBySource: [Int64: UUID] = [:]
    var groupUpdates: [String: Set<UUID>] = [:]
    var existingGroups: [ClipboardGroup] = []
    var existingMemberships: [String: Set<UUID>] = [:]
    var titleUpdates: [String: String] = [:]
    var existingTitles: [String: String] = [:]

    var hasGroupChanges: Bool { !groupsToCreate.isEmpty || !groupUpdates.isEmpty }
    var hasChanges: Bool { !entries.isEmpty || hasGroupChanges || !titleUpdates.isEmpty }

    var requiredCount: Int { existingHashes.count + entries.count }
    var requiredBytes: Int64 { existingBytes + entries.reduce(0) { $0 + $1.byteCount } }
    var needsExpansion: Bool { limits.itemCount > 0 && requiredCount > limits.itemCount }

    func selectedEntries(expand: Bool) -> [PasteImportEntry] {
        guard !expand, limits.itemCount > 0 else { return entries }
        return Array(entries.prefix(max(0, limits.itemCount - existingHashes.count)))
    }

}

struct PasteImportResult: Sendable {
    let added: Int
    let duplicates: Int
    let skipped: [String: Int]
    let capacitySkipped: Int
    let groupsAdded: Int
    let recordsUpdated: Int
    let titlesUpdated: Int
}

enum PasteImportError: LocalizedError {
    case unsupportedStore, unreadable, storage, insufficientSpace, sourceChanged, settingsChanged
    case stalePreview(PasteImportPreview)

    var errorDescription: String? { L10n.tr(messageKey) }

    var messageKey: String {
        switch self {
        case .settingsChanged: return "收录限制已更改，请重新扫描。"
        case .unsupportedStore: return "暂不支持这个 Paste 数据格式。请选择包含 db.sqlite 的 Paste 数据文件夹。"
        case .unreadable: return "无法读取 Paste 数据。请确认已退出 Paste，并重新选择数据文件夹授权访问。"
        case .storage: return "无法保存导入结果，已有历史未被本次导入替换。请检查存储空间和目录权限后重试。"
        case .insufficientSpace: return "磁盘剩余空间不足，请释放空间后重试。"
        case .sourceChanged: return "扫描期间 Paste 数据发生了变化。请退出 Paste 后重新扫描。"
        case .stalePreview: return "扫描后历史记录发生了变化，已更新导入数量和容量，请重新确认。"
        }
    }
}
