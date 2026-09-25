import Foundation

struct ClipboardGroup: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
}
import UniformTypeIdentifiers

enum ClipboardContentType: String, Codable, CaseIterable, Identifiable {
    case text
    case url
    case image
    case file

    var id: String { rawValue }

    static func forText(_ text: String) -> ClipboardContentType {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              let url = URLComponents(string: value),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty, url.url != nil else { return .text }
        return .url
    }

    var title: String {
        switch self {
        case .text: L10n.tr("文本")
        case .url: L10n.tr("链接")
        case .image: L10n.tr("图片")
        case .file: L10n.tr("文件")
        }
    }

    var systemImage: String {
        switch self {
        case .text: "text.alignleft"
        case .url: "link"
        case .image: "photo"
        case .file: "doc"
        }
    }
}

struct ClipboardItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let type: ClipboardContentType
    var textContent: String?
    var assetFilename: String?
    var thumbnailFilename: String?
    var filePaths: [String]
    var sourceAppName: String
    var sourceBundleID: String
    let contentHash: String
    let createdAt: Date
    var lastCopiedAt: Date
    var groupIDs: [UUID]? = nil
    var customTitle: String? = nil

    var imageFileURL: URL? {
        guard type == .file, filePaths.count == 1, let path = filePaths.first else { return nil }
        let url = URL(fileURLWithPath: path)
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else { return nil }
        return url
    }

    var hasImage: Bool {
        type == .image || imageFileURL != nil
    }

    var displaySourceAppName: String {
        if sourceAppName == "未知应用", sourceBundleID.isEmpty { return L10n.tr("未知应用") }
        if sourceAppName == "Paste（导入）", sourceBundleID == "com.wiheads.paste" { return L10n.tr("Paste（导入）") }
        return sourceAppName
    }

    var displayTitle: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        return automaticTitle
    }

    var automaticTitle: String {
        switch type {
        case .text:
            return textContent?.firstLine ?? L10n.tr("空文本")
        case .url:
            return textContent.map { String($0.prefix(200)) } ?? L10n.tr("链接")
        case .image:
            return L10n.tr("图片")
        case .file:
            if filePaths.count == 1, let path = filePaths.first {
                return URL(fileURLWithPath: path).lastPathComponent
            }
            return L10n.tr("%d 个文件", filePaths.count)
        }
    }

    var displayDetail: String {
        switch type {
        case .text:
            return textContent?.replacingOccurrences(of: "\n", with: " ") ?? ""
        case .url:
            return textContent ?? ""
        case .image:
            return sourceAppName
        case .file:
            return filePaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "、")
        }
    }

}

extension String {
    fileprivate var firstLine: String {
        let start = drop(while: { $0.isWhitespace })
        return String(start.prefix(200).prefix(while: { !$0.isNewline }))
    }
}
