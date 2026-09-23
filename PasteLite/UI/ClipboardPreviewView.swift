import AppKit
import ImageIO
import SwiftUI

struct ClipboardPreviewView: View {
    let item: ClipboardItem
    let timeLabel: String?
    let assetURL: URL?
    let onPaste: () -> Void

    @State private var image: CGImage?
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("内容预览")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(item.displayTitle)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(2)

            previewContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("\(item.sourceAppName) · \(item.type.title)")
                if let timeLabel {
                    Text(timeLabel)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Button(action: onPaste) {
                Label("粘贴到原应用", systemImage: "return")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .controlSize(.regular)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.025))
        .task(id: assetURL) {
            image = nil
            isLoading = false
            guard item.hasImage, let assetURL else { return }
            isLoading = true
            let loadedImage = await ClipboardImageLoader.load(from: assetURL, maxPixelSize: 1_200)

            guard !Task.isCancelled else { return }
            image = loadedImage
            isLoading = false
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if item.hasImage {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                        .accessibilityLabel("完整图片预览")
                } else if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "photo")
                            .font(.system(size: 24))
                        Text("图片文件已不存在或无法读取")
                            .font(.system(size: 12))
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                    .padding(16)
                }
            }
        } else {
            let text = item.type == .file
                ? item.filePaths.joined(separator: "\n\n")
                : item.textContent ?? ""
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(String(text.prefix(10_000)))
                        .font(.system(size: 13))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if text.count > 10_000 {
                        Text("仅预览前 10,000 字，粘贴时使用完整内容。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
