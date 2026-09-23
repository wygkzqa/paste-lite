import Foundation
import UniformTypeIdentifiers

enum ClipboardContentType: String, Codable, CaseIterable, Identifiable {
    case text
    case url
    case image
    case file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: "文本"
        case .url: "链接"
        case .image: "图片"
        case .file: "文件"
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

struct ClipboardItem: Codable, Identifiable, Equatable {
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

    var imageFileURL: URL? {
        guard type == .file, filePaths.count == 1, let path = filePaths.first else { return nil }
        let url = URL(fileURLWithPath: path)
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else { return nil }
        return url
    }

    var hasImage: Bool {
        type == .image || imageFileURL != nil
    }

    var displayTitle: String {
        switch type {
        case .text:
            return textContent?.trimmingCharacters(in: .whitespacesAndNewlines).firstLine ?? "空文本"
        case .url:
            return textContent ?? "链接"
        case .image:
            return "图片"
        case .file:
            if filePaths.count == 1, let path = filePaths.first {
                return URL(fileURLWithPath: path).lastPathComponent
            }
            return "\(filePaths.count) 个文件"
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
        components(separatedBy: .newlines).first(where: { !$0.isEmpty }) ?? self
    }
}
