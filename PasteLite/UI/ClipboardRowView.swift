import AppKit
import SwiftUI

struct ClipboardRowView: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let item: ClipboardItem
    let timeLabel: String?
    let previewURL: URL?
    let assetURL: URL?
    let quickIndex: Int?
    let isSelected: Bool
    var isCard = false
    @State private var isHovered = false
    @State private var previewImage: CGImage?
    @State private var filesStillExist: Bool?

    private let selectionBlue = Color(red: 0.20, green: 0.43, blue: 0.82)
    private var usesBlueSelection: Bool { isSelected && !settings.usesGradientBackground }
    private var secondaryForeground: Color { usesBlueSelection ? .white.opacity(0.88) : .secondary }
    private var backgroundColor: Color {
        if usesBlueSelection { return selectionBlue }
        if reduceTransparency { return .primary.opacity(isSelected ? 0.1 : 0.025) }
        return .white.opacity(isSelected ? (colorScheme == .dark ? 0.12 : 0.55) : (isHovered ? 0.09 : (isCard ? 0.04 : 0)))
    }

    var body: some View {
        Group {
            if isCard { cardContent }
            else { rowContent }
        }
        .foregroundStyle(usesBlueSelection ? Color.white : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: isCard ? 13 : 12)
                .fill(backgroundColor)
        )
        .overlay {
            RoundedRectangle(cornerRadius: isCard ? 13 : 12)
                .strokeBorder(Color.white.opacity(isSelected ? 0.55 : (isCard ? 0.2 : 0)), lineWidth: 0.5)
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
        .onDisappear { previewImage = nil }
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
            if let quickIndex {
                Text("⌘\(quickIndex)").font(.system(size: 11)).foregroundStyle(secondaryForeground)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(height: 54)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            if item.hasImage {
                preview.frame(height: 70)
                    .overlay(alignment: .topTrailing) { shortcut.padding(5) }
            } else {
                HStack {
                    Image(systemName: item.type.systemImage).foregroundStyle(secondaryForeground)
                    Spacer()
                    shortcut
                }.font(.system(size: 12))
            }
            Text(item.displayTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
                .help(item.displayTitle)
            if !item.hasImage {
                Text(item.displayDetail).font(.system(size: 12)).foregroundStyle(secondaryForeground).lineLimit(3)
            }
            Spacer(minLength: 0)
            metadata
        }
        .padding(11)
        .frame(width: 184, height: 148, alignment: .topLeading)
    }

    private var shortcut: some View {
        Group {
            if let quickIndex {
                Text("⌘\(quickIndex)").font(.system(size: 11)).foregroundStyle(secondaryForeground)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background {
                        if usesBlueSelection {
                            RoundedRectangle(cornerRadius: 4).fill(selectionBlue)
                        } else {
                            RoundedRectangle(cornerRadius: 4).fill(.regularMaterial)
                        }
                    }
            }
        }
    }

    private var metadata: some View {
        HStack(spacing: 4) {
            Text(item.displaySourceAppName)
            if item.type == .file, filesStillExist == false {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(usesBlueSelection ? Color.white : Color.orange)
                    .help(L10n.tr("文件已不存在"))
            }
            if let timeLabel { Text("·"); Text(timeLabel) }
        }
        .font(.system(size: 11)).foregroundStyle(secondaryForeground).lineLimit(1)
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
                        .foregroundStyle(secondaryForeground)
                }
        }
    }
}
