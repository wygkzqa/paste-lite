import AppKit
import SwiftUI

struct ClipboardHistoryView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var viewModel: ClipboardViewModel
    @ObservedObject private var repository: ClipboardRepository
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var searchIsFocused: Bool
    @State private var sheet: ClipboardSheet?
    @State private var showsFilters = false
    @State private var showsPermission = false
    @State private var visibleItemID: UUID?

    init(viewModel: ClipboardViewModel) {
        self.viewModel = viewModel
        repository = viewModel.repository
    }

    private var layout: ClipboardLayout { settings.clipboardLayout }

    var body: some View {
        VStack(spacing: 8) {
            searchHeader
            groupTabs
            historyContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .padding(12)
        .frame(width: layout.width, height: layout.height)
        .modifier(ClipboardGlass(cornerRadius: ClipboardGlass.panelCornerRadius))
        .ignoresSafeArea()
        .sheet(item: $sheet) { destination in
            switch destination {
            case .edit(let item):
                ClipboardItemForm(item: item, repository: repository,
                    timeLabel: viewModel.timeLabel(for: item), isEditing: true, onPaste: {})
            case .editGroup(let group):
                ClipboardGroupEditor(repository: repository, group: group) { saved in
                    if group == nil { viewModel.groupFilter = .group(saved.id) }
                }
            case .createGroup(let ids):
                ClipboardGroupEditor(repository: repository, group: nil, itemIDs: ids, onSave: { _ in })
            case .deleteGroup(let group):
                ClipboardGroupDeleteConfirmation(repository: repository, group: group)
            case .deleteItems(let ids):
                ClipboardDeleteConfirmation(repository: repository, itemIDs: ids)
            case .error(let message):
                VStack(alignment: .leading, spacing: 14) {
                    Text(message).fixedSize(horizontal: false, vertical: true)
                    HStack { Spacer(); Button(L10n.tr("关闭")) { sheet = nil }.keyboardShortcut(.cancelAction) }
                }.padding(20).frame(width: 340)
            case .preview(let item):
                ClipboardItemForm(item: item, repository: repository,
                    timeLabel: viewModel.timeLabel(for: item), isEditing: false,
                    onPaste: { sheet = nil; viewModel.paste(item) })
            }
        }
        .onChange(of: sheet?.id) { updateOverlayState() }
        .onChange(of: showsFilters) { updateOverlayState() }
        .onChange(of: showsPermission) { updateOverlayState() }
        .onChange(of: viewModel.presentationToken) {
            sheet = nil
            showsFilters = false
            showsPermission = false
            DispatchQueue.main.async { searchIsFocused = true }
        }
    }

    private func updateOverlayState() {
        viewModel.isPresentingOverlay = sheet != nil || showsFilters || showsPermission
    }

    private var searchHeader: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.tr("搜索剪贴板…"), text: $viewModel.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchIsFocused)
                    .accessibilityLabel(L10n.tr("搜索标题、文本、链接、文件或来源应用"))
                if !viewModel.query.isEmpty {
                    Button { viewModel.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain).help(L10n.tr("清除搜索"))
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(.white.opacity(colorScheme == .dark ? 0.06 : 0.2), in: Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(colorScheme == .dark ? 0.12 : 0.4), lineWidth: 0.5).allowsHitTesting(false) }

            Button { showsFilters.toggle() } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(viewModel.contentFilter != .all || !viewModel.sourceFilter.isEmpty ? Color.accentColor : Color.secondary)
                    .frame(width: 28, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("筛选"))
            .help(L10n.tr("筛选类型和来源"))
            .popover(isPresented: $showsFilters) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L10n.tr("筛选")).font(.headline)
                    Picker(L10n.tr("类型"), selection: $viewModel.contentFilter) {
                        ForEach(ContentFilter.allCases) { Text($0.title).tag($0) }
                    }
                    Picker(L10n.tr("来源"), selection: $viewModel.sourceFilter) {
                        Text(L10n.tr("所有应用")).tag("")
                        ForEach(viewModel.sourceApps, id: \.self) { Text(viewModel.sourceAppNames[$0] ?? $0).tag($0) }
                    }
                    Button(L10n.tr("清除筛选")) {
                        viewModel.contentFilter = .all
                        viewModel.sourceFilter = ""
                    }
                }.padding(18).frame(width: 280, alignment: .leading)
            }
        }
    }

    private var groupTabs: some View {
        HStack(spacing: 5) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        groupTab(L10n.tr("全部"), filter: .all)
                        ForEach(repository.groups) { group in
                            groupTab(group.name, filter: .group(group.id))
                                .overlay {
                                    ClipboardGroupContextMenu(
                                        onOpen: { viewModel.isPresentingContextMenu = true },
                                        onClose: { viewModel.isPresentingContextMenu = false },
                                        onRename: { sheet = .editGroup(group) },
                                        onDelete: { sheet = .deleteGroup(group) })
                                }
                        }
                    }
                }
                .scrollIndicators(.never)
                .onChange(of: viewModel.groupFilter) {
                    proxy.scrollTo(viewModel.groupFilter)
                }
            }
            Button { sheet = .editGroup(nil) } label: {
                Image(systemName: "plus").frame(width: 24, height: 24)
            }.buttonStyle(.plain).accessibilityLabel(L10n.tr("新建分组…"))
        }
        .frame(height: 28)
    }

    private func groupTab(_ title: String, filter: ClipboardGroupFilter) -> some View {
        Button { viewModel.groupFilter = filter } label: {
            Text(title).font(.system(size: 12)).lineLimit(1).frame(maxWidth: 160)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(.primary.opacity(viewModel.groupFilter == filter ? 0.16 : 0), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
        .id(filter)
        .accessibilityAddTraits(viewModel.groupFilter == filter ? .isSelected : [])
    }

    @ViewBuilder
    private var historyContent: some View {
        if let error = viewModel.errorMessage ?? repository.errorMessage {
            VStack(spacing: 10) {
                Text(L10n.tr(error)).font(.callout).foregroundStyle(.secondary)
                Button(L10n.tr("重试")) { viewModel.retrySearch() }
            }
        } else if viewModel.filteredItems.isEmpty {
            if viewModel.showsInitialLoading { ProgressView().controlSize(.small) }
            else {
                VStack(spacing: 8) {
                    Image(systemName: "clipboard").font(.system(size: 25, weight: .light)).foregroundStyle(.secondary)
                    Text(repository.totalCount == 0 ? L10n.tr("复制的内容，会出现在这里") : L10n.tr("没有匹配的记录"))
                        .font(.system(size: 13, weight: .medium))
                    Text(viewModel.groupFilter == .all ? L10n.tr("试试其他关键词，或调整筛选条件。") : L10n.tr("在全部历史中选择记录，即可加入分组。"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView(layout == .cards ? .horizontal : .vertical) {
                    if layout == .cards {
                        LazyHStack(spacing: 8) { historyItems }
                            .scrollTargetLayout()
                            .padding(.horizontal, 1)
                    } else {
                        LazyVStack(spacing: 2) { historyItems }
                            .scrollTargetLayout()
                    }
                }
                .scrollIndicators(.never)
                // Track the visible record so new captures do not displace the content being read.
                .scrollPosition(id: $visibleItemID)
                .id(layout)
                .onReceive(viewModel.keyboardScrollRequests) { id in
                    proxy.scrollTo(id)
                }
            }
        }
    }

    private var historyItems: some View {
        ForEach(viewModel.filteredItems) { item in
            ClipboardRowView(item: item, timeLabel: viewModel.timeLabel(for: item),
                previewURL: repository.previewURL(for: item), assetURL: repository.assetURL(for: item),
                isSelected: viewModel.selectedIDs.contains(item.id),
                isCard: layout == .cards)
                .overlay {
                    ClipboardItemContextMenu(
                        onSelect: { modifiers in
                            searchIsFocused = false
                            viewModel.selectForClick(item, toggling: modifiers.contains(.command), extending: modifiers.contains(.shift))
                        },
                        onDoubleClick: { viewModel.select(item); viewModel.pasteSelected() },
                        onOpen: { searchIsFocused = false; viewModel.selectForContextMenu(item); viewModel.isPresentingContextMenu = true },
                        onClose: { viewModel.isPresentingContextMenu = false },
                        onEdit: { sheet = .edit(item) },
                        onPreview: { sheet = .preview(item) },
                        groups: repository.groups,
                        selection: { viewModel.selectionForContextMenu },
                        onSelectAll: viewModel.selectAll,
                        onGroup: changeGroup,
                        onNewGroup: { sheet = .createGroup($0) },
                        onDelete: { sheet = .deleteItems($0) })
                }
                .id(item.id)
                .onAppear { viewModel.loadMoreIfNeeded(item) }
        }
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Text(viewModel.isSelectingAll ? L10n.tr("正在全选…") : (viewModel.selectedIDs.count > 1 ? L10n.tr("已选 %d 条", viewModel.selectedIDs.count) : L10n.tr("%d 条记录", viewModel.resultCount)))
                .foregroundStyle(.secondary)
            if !viewModel.hasAccessibilityPermission {
                Button { showsPermission.toggle() } label: {
                    Image(systemName: "exclamationmark.shield").foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("辅助功能权限"))
                .popover(isPresented: $showsPermission) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.tr("授予辅助功能权限后，可以直接粘贴到原应用；未授权时只会复制到剪贴板。"))
                            .font(.callout)
                        Button(L10n.tr("打开设置")) {
                            showsPermission = false
                            viewModel.requestAccessibilityPermission()
                        }
                    }.padding(18).frame(width: 290)
                }
            }
            Spacer(minLength: 4)
            Text("↑↓ \(L10n.tr("选择"))  ↵ \(L10n.tr("粘贴"))").foregroundStyle(.secondary)
            Button {
                settings.clipboardLayout = layout == .list ? .cards : .list
            } label: {
                Label(layout == .list ? L10n.tr("切换为卡片") : L10n.tr("切换为列表"),
                      systemImage: layout == .list ? "rectangle.split.3x1" : "list.bullet")
                    .labelStyle(.iconOnly)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(layout == .list ? L10n.tr("切换为卡片") : L10n.tr("切换为列表"))
        }
        .font(.system(size: 11))
        .frame(height: 24)
        .padding(.top, 5)
        .overlay(alignment: .top) { Rectangle().fill(.primary.opacity(0.07)).frame(height: 0.5) }
    }

    private func changeGroup(_ groupID: UUID, _ itemIDs: Set<UUID>, _ included: Bool) {
        Task {
            do { try await repository.setGroup(groupID, for: itemIDs, included: included) }
            catch { sheet = .error(error.localizedDescription) }
        }
    }
}
