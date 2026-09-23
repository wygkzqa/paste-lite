import AppKit
import SwiftUI

struct ClipboardRowView: View {
    let item: ClipboardItem
    let timeLabel: String?
    let previewURL: URL?
    let quickIndex: Int?
    let isSelected: Bool
    @State private var isHovered = false
    @State private var previewImage: CGImage?

    var body: some View {
        HStack(spacing: 12) {
            preview
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    Text(item.sourceAppName)
                    Text("·")
                    Text(item.type.title)
                    if item.type == .file, !filesStillExist {
                        Text("· 文件已不存在")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                if let timeLabel {
                    Text(timeLabel)
                }
                if let quickIndex {
                    Text("⌘\(quickIndex)")
                        .monospacedDigit()
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.indigo.opacity(0.13) : Color.primary.opacity(isHovered ? 0.04 : 0))
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .task(id: previewURL) {
            previewImage = nil
            guard item.hasImage, let previewURL else { return }
            let image = await ClipboardImageLoader.load(from: previewURL, maxPixelSize: 128)
            guard !Task.isCancelled else { return }
            previewImage = image
        }
    }

    @ViewBuilder
    private var preview: some View {
        if item.hasImage,
           let image = previewImage {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("图片缩略图")
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.05))
                .overlay {
                    Image(systemName: item.type.systemImage)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(isSelected ? Color.indigo : Color.secondary)
                }
        }
    }

    private var filesStillExist: Bool {
        item.filePaths.allSatisfy { FileManager.default.fileExists(atPath: $0) }
    }

}
