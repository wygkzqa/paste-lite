import AppKit
import SwiftUI

struct ClipboardRowView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    let item: ClipboardItem
    let timeLabel: String?
    let previewURL: URL?
    let assetURL: URL?
    let isSelected: Bool
    var isCard = false
    var sourceIconRevision = 0
    var loadSourceIcon: () async -> URL? = { nil }
    @State private var isHovered = false
    @State private var previewImage: CGImage?
    @State private var filesStillExist: Bool?
    @State private var sourceIcon: CGImage?

    private var backgroundColor: Color {
        if isSelected { return .blue.opacity(colorScheme == .dark ? 0.12 : 0.06) }
        if reduceTransparency { return .primary.opacity(0.025) }
        return .white.opacity(isHovered ? 0.09 : (isCard ? 0.04 : 0))
    }

    var body: some View {
        Group {
            if isCard { cardContent }
            else { rowContent }
        }
        .foregroundStyle(Color.primary)
        .background(
            RoundedRectangle(cornerRadius: isCard ? 13 : 12)
                .fill(backgroundColor)
        )
        .overlay {
            RoundedRectangle(cornerRadius: isCard ? 13 : 12)
                .strokeBorder(isSelected ? Color.blue : Color.white.opacity(isCard ? 0.2 : 0), lineWidth: isSelected ? 1.5 : 0.5)
                .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .task(id: "\(previewURL?.path ?? "")-\(isCard)") {
            previewImage = nil
            filesStillExist = nil
            if item.hasImage, let previewURL {
                let image = await ClipboardImageLoader.load(from: previewURL, fallbackURL: assetURL, maxPixelSize: isCard ? 400 : 96)
                guard !Task.isCancelled else { return }
                previewImage = image
            }
            if item.type == .file {
                let exists = await ClipboardFileStatus.filesExist(item.filePaths)
                guard !Task.isCancelled else { return }
                filesStillExist = exists
            }
        }
        .task(id: "\(item.sourceBundleID)-\(item.lastCopiedAt.timeIntervalSince1970)-\(sourceIconRevision)") {
            sourceIcon = nil
            guard let url = await loadSourceIcon(), !Task.isCancelled else { return }
            let image = await ClipboardImageLoader.load(from: url, maxPixelSize: 64)
            guard !Task.isCancelled else { return }
            sourceIcon = image
        }
        .onDisappear { previewImage = nil; sourceIcon = nil }
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            preview.frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    .help(item.displayTitle)
                metadata
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(height: 54)
    }

    private var cardTitle: String {
        if let title = item.customTitle, !title.isEmpty { return title }
        return item.type.title
    }

    private var cardContent: some View {
        let hasCustomTitle = item.customTitle?.isEmpty == false
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: item.type.systemImage)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text(cardTitle).font(.system(size: hasCustomTitle ? 12 : 11)).lineLimit(1)
                    .foregroundStyle(.secondary)
                    .help(cardTitle)
            }
            if item.hasImage {
                preview.frame(height: 70)
            } else {
                Text(item.displayDetail).font(.system(size: 12)).foregroundStyle(.primary).lineLimit(4)
            }
            Spacer(minLength: 0)
            metadata
        }
        .padding(11)
        .frame(width: 184, height: 148, alignment: .topLeading)
    }

    private var metadata: some View {
        HStack(spacing: 4) {
            if let sourceIcon {
                Image(decorative: sourceIcon, scale: 1).resizable().scaledToFit()
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
            }
            Text(item.displaySourceAppName)
                .truncationMode(.tail)
                .help(item.displaySourceAppName)
            if item.type == .file, filesStillExist == false {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help(L10n.tr("文件已不存在"))
                    .fixedSize()
            }
            if let timeLabel { Text("·").fixedSize(); Text(timeLabel).fixedSize() }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
    }

    @ViewBuilder
    private var preview: some View {
        if item.hasImage, let image = previewImage {
            Image(decorative: image, scale: 1).resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.primary.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .accessibilityLabel(L10n.tr("图片缩略图"))
        } else {
            RoundedRectangle(cornerRadius: 7).fill(.primary.opacity(0.045))
                .overlay {
                    Image(systemName: item.type.systemImage).font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
        }
    }
}
