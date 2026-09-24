import SwiftUI

struct ClipboardItemForm: View {
    let item: ClipboardItem
    let repository: ClipboardRepository
    let timeLabel: String
    let isEditing: Bool
    let onPaste: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var fullItem: ClipboardItem?
    @State private var title = ""
    @State private var content = ""
    @State private var image: CGImage?
    @State private var imageIsLoading = false
    @State private var loadFailed = false
    @State private var saving = false
    @State private var error: String?
    @FocusState private var titleIsFocused: Bool

    private var canEditContent: Bool { item.type == .text || item.type == .url }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isEditing ? L10n.tr("编辑记录") : L10n.tr("内容预览")).font(.headline)

            if let loaded = fullItem {
                Text(L10n.tr("标题")).font(.caption).foregroundStyle(.secondary)
                if isEditing {
                    TextField(loaded.automaticTitle, text: $title)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(L10n.tr("标题"))
                        .focused($titleIsFocused)
                    Text(L10n.tr("留空则使用内容自动生成的标题。"))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        Text(loaded.displayTitle).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 52)
                }

                Text(L10n.tr("内容")).font(.caption).foregroundStyle(.secondary)
                contentField(loaded)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if isEditing && !canEditContent {
                    Text(L10n.tr("图片和文件仅支持编辑标题。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("\(loaded.displaySourceAppName) · \(loaded.type.title) · \(timeLabel)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                VStack(spacing: 10) {
                    if loadFailed {
                        Text(L10n.tr("无法读取历史记录，请重试。"))
                        Button(L10n.tr("重试")) { Task { await load() } }
                    } else { ProgressView().controlSize(.small) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Spacer()
                Button(isEditing ? L10n.tr("取消") : L10n.tr("关闭")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if isEditing {
                    Button(L10n.tr("保存"), action: save)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(fullItem == nil)
                } else {
                    Button(L10n.tr("粘贴到原应用"), action: onPaste).disabled(fullItem == nil)
                }
            }
        }
        .padding(20).frame(width: 420, height: 480)
        .disabled(saving)
        .task(id: item.id) { await load() }
        .task(id: repository.assetURL(for: item)) {
            image = nil
            imageIsLoading = false
            guard item.hasImage, let url = repository.assetURL(for: item) else { return }
            imageIsLoading = true
            let loaded = await ClipboardImageLoader.load(from: url, maxPixelSize: 1_200)
            guard !Task.isCancelled else { return }
            image = loaded
            imageIsLoading = false
        }
    }

    @ViewBuilder
    private func contentField(_ loaded: ClipboardItem) -> some View {
        if isEditing && canEditContent {
            TextEditor(text: $content)
                .font(.system(size: 13))
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.15), lineWidth: 0.5) }
                .accessibilityLabel(L10n.tr("内容"))
        } else if loaded.hasImage {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor))
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit().padding(8)
                        .accessibilityLabel(L10n.tr("完整图片预览"))
                } else if imageIsLoading { ProgressView().controlSize(.small) }
                else {
                    Text(L10n.tr("图片文件已不存在或无法读取"))
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).padding(16)
                }
            }
        } else {
            let text = loaded.type == .file ? loaded.filePaths.joined(separator: "\n\n") : loaded.textContent ?? ""
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(text.prefix(10_000))).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if text.count > 10_000 {
                        Text(L10n.tr("仅预览前 10,000 字，粘贴时使用完整内容。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(8)
            }
            .font(.system(size: 13))
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func load() async {
        loadFailed = false
        fullItem = nil
        do {
            let loaded = try await repository.item(id: item.id)
            guard !Task.isCancelled else { return }
            fullItem = loaded
            loadFailed = loaded == nil
            title = loaded?.customTitle ?? ""
            content = loaded?.textContent ?? ""
            titleIsFocused = isEditing
        } catch { if !Task.isCancelled { loadFailed = true } }
    }

    private func save() {
        guard fullItem != nil, !saving else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await repository.editItem(id: item.id, title: title, textContent: canEditContent ? content : nil)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
