import SwiftUI

struct ClipboardHistoryView: View {
    @ObservedObject var viewModel: ClipboardViewModel
    @FocusState private var searchIsFocused: Bool
    @State private var showsPreview = false

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            filterBar

            if !viewModel.hasAccessibilityPermission {
                permissionBanner
            }

            Divider()

            HStack(spacing: 0) {
                historyContent
                    .frame(maxWidth: .infinity)

                if showsPreview {
                    Divider()
                    if let item = viewModel.selectedItem {
                        ClipboardPreviewView(
                            item: item,
                            timeLabel: viewModel.timeLabels[item.id],
                            assetURL: viewModel.repository.assetURL(for: item),
                            onPaste: { viewModel.pasteSelected() }
                        )
                        .id(item.id)
                        .frame(width: 270)
                    } else {
                        Text("选择一条记录以预览")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 270)
                    }
                }
            }

            Divider()
            footer
        }
        .frame(width: 760, height: 560)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .onChange(of: viewModel.presentationToken) {
            DispatchQueue.main.async {
                searchIsFocused = true
            }
        }
        .onChange(of: viewModel.query) {
            viewModel.selectedID = viewModel.filteredItems.first?.id
        }
        .onChange(of: viewModel.contentFilter) {
            viewModel.selectedID = viewModel.filteredItems.first?.id
        }
        .onChange(of: viewModel.sourceFilter) {
            viewModel.selectedID = viewModel.filteredItems.first?.id
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19))
                .foregroundStyle(.secondary)

            TextField("搜索剪贴板历史…", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .focused($searchIsFocused)
                .accessibilityLabel("搜索文本、链接、文件或来源应用")

            if !viewModel.query.isEmpty {
                Button {
                    viewModel.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }

            Text("⇧⌘V")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 3) {
                ForEach(ContentFilter.allCases) { filter in
                    Button {
                        viewModel.contentFilter = filter
                        searchIsFocused = true
                    } label: {
                        Text(filter.title)
                            .font(.system(size: 12, weight: viewModel.contentFilter == filter ? .medium : .regular))
                            .foregroundStyle(viewModel.contentFilter == filter ? .primary : .secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Color.primary.opacity(viewModel.contentFilter == filter ? 0.07 : 0),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(viewModel.contentFilter == filter ? .isSelected : [])
                }
            }

            Spacer(minLength: 12)

            Picker("来源", selection: $viewModel.sourceFilter) {
                Text("所有应用").tag("")
                ForEach(viewModel.sourceApps, id: \.self) { app in
                    Text(app).tag(app)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .labelsHidden()
            .frame(width: 130)

            Button {
                showsPreview.toggle()
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 14))
                    .foregroundStyle(showsPreview ? Color.indigo : Color.secondary)
                    .frame(width: 30, height: 28)
                    .background(
                        Color.indigo.opacity(showsPreview ? 0.12 : 0),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
            }
            .buttonStyle(.plain)
            .help(showsPreview ? "收起内容预览" : "展开内容预览")
            .accessibilityLabel(showsPreview ? "收起内容预览" : "展开内容预览")
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    private var permissionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield")
            Text("授予辅助功能权限后，可以直接粘贴到原应用；未授权时只会复制到剪贴板。")
                .font(.system(size: 12))
            Spacer()
            Button("打开设置") {
                viewModel.requestAccessibilityPermission()
            }
            .controlSize(.small)
            .help("打开辅助功能设置，为 Paste Lite 开启权限")
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 22)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var historyContent: some View {
        let items = viewModel.filteredItems
        if items.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: viewModel.repository.items.isEmpty ? "clipboard" : "magnifyingglass")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(viewModel.repository.items.isEmpty ? "复制的内容，会出现在这里" : "没有匹配的记录")
                    .font(.system(size: 14, weight: .medium))
                Text(viewModel.repository.items.isEmpty ? "文字、链接、图片和文件，随时找回。" : "试试其他关键词，或调整筛选条件。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if !viewModel.query.isEmpty || !viewModel.sourceFilter.isEmpty {
                    Button("清除搜索和来源筛选") {
                        viewModel.query = ""
                        viewModel.sourceFilter = ""
                    }
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        let group = viewModel.dateGroups[item.id] ?? "新记录"
                        VStack(alignment: .leading, spacing: 2) {
                            if index == 0 || group != (viewModel.dateGroups[items[index - 1].id] ?? "新记录") {
                                Text(group)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, index == 0 ? 4 : 12)
                                    .padding(.bottom, 6)
                            }

                            ClipboardRowView(
                                item: item,
                                timeLabel: viewModel.timeLabels[item.id],
                                previewURL: viewModel.repository.previewURL(for: item),
                                quickIndex: index < 9 ? index + 1 : nil,
                                isSelected: viewModel.selectedID == item.id
                            )
                            .onTapGesture(count: 2) {
                                viewModel.select(item)
                                viewModel.pasteSelected()
                            }
                            // Selection should not wait for the double-click recognizer to fail.
                            .simultaneousGesture(TapGesture().onEnded {
                                viewModel.select(item)
                            })
                        }
                        .id(item.id)
                    }
                }
                .padding(10)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var footer: some View {
        HStack {
            Text("\(viewModel.filteredItems.count) 条记录")
            Spacer()
            HStack(spacing: 12) {
                shortcutHint("↑↓", title: "选择")
                shortcutHint("↩", title: "粘贴")
                shortcutHint("⌘1–9", title: "快速粘贴")
                shortcutHint("esc", title: "关闭")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.025))
    }

    private func shortcutHint(_ keys: String, title: String) -> some View {
        HStack(spacing: 4) {
            Text(keys)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(title)
        }
    }
}
