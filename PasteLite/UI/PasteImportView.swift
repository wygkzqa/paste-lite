import AppKit
import SwiftUI

@MainActor
final class PasteImportViewModel: ObservableObject {
    @Published var directories: [URL] = []
    @Published var selectedDirectory: URL?
    @Published var isScanning = false
    @Published var isSaving = false
    @Published var processed = 0
    @Published var total = 0
    @Published var preview: PasteImportPreview?
    @Published var result: PasteImportResult?
    @Published var message: String?
    @Published var expandCapacity = true
    private(set) var batch: PasteImportBatch?
    private let repository: ClipboardRepository
    private let isPasteRunning: () -> Bool
    private var scanTask: Task<PasteImportBatch, Error>?
    private var scanID = UUID()
    var onShowHistory: (() -> Void)?
    var onClose: (() -> Void)?

    init(repository: ClipboardRepository, isPasteRunning: @escaping () -> Bool = {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.wiheads.paste").isEmpty
    }) {
        self.repository = repository
        self.isPasteRunning = isPasteRunning
        directories = PasteImportService.candidateDirectories
        if directories.count == 1 { selectedDirectory = directories.first }
    }

    var importCount: Int { preview?.selectedEntries(expand: expandCapacity).count ?? 0 }
    var canImport: Bool { importCount > 0 || preview?.hasGroupChanges == true || preview?.titleUpdates.isEmpty == false }
    var skipped: [String: Int] { result?.skipped ?? batch?.skipped ?? [:] }

    func chooseDirectory() {
        guard !isScanning, !isSaving else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.tr("选择 Paste 数据文件夹")
        panel.prompt = L10n.tr("选择")
        panel.message = L10n.tr("请选择包含 db.sqlite 和 .db_SUPPORT 的文件夹。")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = selectedDirectory
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.selectedDirectory = url
            self?.preview = nil
            self?.batch = nil
            self?.result = nil
            self?.message = nil
        }
    }

    func scan() {
        guard let directory = selectedDirectory, !isScanning, !isSaving else { return }
        guard !isPasteRunning() else {
            message = "请先退出 Paste，再点击扫描。导入不会修改 Paste 的原始数据。"
            return
        }
        preview = nil
        result = nil
        batch = nil
        message = nil
        processed = 0
        total = 0
        isScanning = true
        let id = UUID()
        scanID = id
        let limits = repository.limits
        let task = Task.detached(priority: .userInitiated) { [self] in
            let access = directory.startAccessingSecurityScopedResource()
            defer { if access { directory.stopAccessingSecurityScopedResource() } }
            return try PasteImportService.scan(directory: directory, limits: limits) { processed, total in
                Task { @MainActor [self] in
                    guard self.scanID == id else { return }
                    self.processed = processed
                    self.total = total
                }
            }
        }
        scanTask = task
        Task {
            do {
                let batch = try await task.value
                guard scanID == id else { return }
                let preview = try await repository.previewImport(batch)
                guard scanID == id else { return }
                self.batch = batch
                self.preview = preview
            } catch is CancellationError {
                if scanID == id { message = "已取消扫描，历史记录未更改。" }
            } catch {
                if scanID == id { message = (error as? PasteImportError)?.messageKey ?? "读取失败，请检查目录权限和剩余空间后重试。" }
            }
            if scanID == id {
                isScanning = false
                scanTask = nil
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanID = UUID()
        isScanning = false
        batch = nil
        preview = nil
        message = "已取消扫描，历史记录未更改。"
    }

    func importRecords() {
        guard let batch, let preview, !isSaving, canImport else { return }
        isSaving = true
        message = nil
        Task {
            do {
                result = try await repository.importBatch(batch, preview: preview, expand: expandCapacity)
                self.preview = nil
                self.batch = nil
            } catch PasteImportError.stalePreview(let current) {
                self.preview = current
                message = PasteImportError.stalePreview(current).messageKey
            } catch {
                message = (error as? PasteImportError)?.messageKey ?? "保存失败，请重试。"
            }
            isSaving = false
        }
    }
}

@MainActor
final class PasteImportWindowController: NSWindowController, NSWindowDelegate {
    let viewModel: PasteImportViewModel

    init(repository: ClipboardRepository, onShowHistory: @escaping () -> Void) {
        viewModel = PasteImportViewModel(repository: repository)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 630),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false
        )
        super.init(window: window)
        window.title = L10n.tr("从 Paste 导入")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PasteImportView(viewModel: viewModel))
        window.delegate = self
        window.center()
        viewModel.onShowHistory = { [weak self] in
            self?.close()
            onShowHistory()
        }
        viewModel.onClose = { [weak self] in self?.close() }
    }

    required init?(coder: NSCoder) { nil }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !viewModel.isSaving else { return false }
        viewModel.cancelScan()
        return true
    }
}

struct PasteImportView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var viewModel: PasteImportViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 30)).foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("把历史带到 Paste Lite")).font(.title2.weight(.semibold))
                    Text(L10n.tr("本机读取 · 自动去重 · 保留原始时间")).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let result = viewModel.result {
                        resultContent(result)
                    } else {
                        sourceContent
                        if viewModel.isScanning {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(L10n.tr("正在读取和准备记录…"))
                                ProgressView(value: Double(viewModel.processed), total: Double(max(viewModel.total, 1)))
                                Text(L10n.tr("已处理 %d / %d 条", viewModel.processed, viewModel.total)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let preview = viewModel.preview { previewContent(preview) }
                    }
                    if !viewModel.skipped.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.tr("无法导入的内容")).font(.headline)
                            ForEach(viewModel.skipped.keys.sorted(), id: \.self) { reason in
                                LabeledContent(L10n.tr(reason), value: L10n.tr("%d 条", viewModel.skipped[reason] ?? 0))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .id(L10n.language)
                        }
                    }
                    if let message = viewModel.message {
                        Label(L10n.tr(message), systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(24)
            }
            Divider()
            HStack {
                if viewModel.isSaving {
                    ProgressView().controlSize(.small)
                    Text(L10n.tr("正在保存，请稍候…")).foregroundStyle(.secondary)
                } else if viewModel.isScanning {
                    Button(L10n.tr("取消扫描")) { viewModel.cancelScan() }
                }
                Spacer()
                if viewModel.result != nil {
                    Button(L10n.tr("查看历史")) { viewModel.onShowHistory?() }
                        .buttonStyle(.borderedProminent).tint(.indigo)
                } else if viewModel.preview != nil {
                    Button(L10n.tr("重新扫描")) { viewModel.scan() }.disabled(viewModel.isSaving)
                    if viewModel.preview?.entries.isEmpty == true && !viewModel.canImport {
                        Button(L10n.tr("完成")) { viewModel.cancelScan(); viewModel.onClose?() }
                            .buttonStyle(.borderedProminent).tint(.indigo)
                    } else {
                        Button(viewModel.importCount == 0 ? L10n.tr("导入分组与标题") : L10n.tr("导入 %d 条", viewModel.importCount)) { viewModel.importRecords() }
                            .buttonStyle(.borderedProminent).tint(.indigo)
                            .disabled(viewModel.isSaving || !viewModel.canImport)
                    }
                } else {
                    Button(L10n.tr("扫描数据")) { viewModel.scan() }
                        .buttonStyle(.borderedProminent).tint(.indigo)
                        .disabled(viewModel.selectedDirectory == nil || viewModel.isScanning)
                }
            }
            .padding(20)
        }
        .frame(width: 540, height: 630)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sourceContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("数据来源")).font(.headline)
            if viewModel.directories.count > 1 {
                Picker(L10n.tr("选择来源"), selection: $viewModel.selectedDirectory) {
                    Text(L10n.tr("请选择")).tag(Optional<URL>.none)
                    ForEach(viewModel.directories, id: \.self) { url in
                        Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).tag(Optional(url))
                    }
                }
                .disabled(viewModel.isScanning || viewModel.isSaving || viewModel.preview != nil)
            }
            if let directory = viewModel.selectedDirectory {
                Text(directory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                Text(L10n.tr("未找到可读取的数据，请选择 Paste 数据文件夹。"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button(L10n.tr("选择数据文件夹…")) { viewModel.chooseDirectory() }
                .disabled(viewModel.isScanning || viewModel.isSaving)
            Text(L10n.tr("扫描前请先退出 Paste。当前已验证 Paste 6.0.3 的数据结构；其他结构会提示暂不支持。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func previewContent(_ preview: PasteImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("扫描完成")).font(.headline)
            LabeledContent(L10n.tr("找到记录"), value: L10n.tr("%d 条", viewModel.batch?.total ?? 0))
            LabeledContent(L10n.tr("可新增"), value: L10n.tr("%d 条", preview.entries.count))
            LabeledContent(L10n.tr("重复，保持已有记录"), value: L10n.tr("%d 条", preview.duplicates))
            LabeledContent(L10n.tr("新增分组"), value: L10n.tr("%d 个", preview.groupsToCreate.count))
            LabeledContent(L10n.tr("补充已有记录的分组"), value: L10n.tr("%d 条", preview.groupUpdates.count))
            LabeledContent(L10n.tr("补充已有记录的标题"), value: L10n.tr("%d 条", preview.titleUpdates.count))
            let counts = Dictionary(grouping: preview.entries, by: { $0.item.type })
            Text(ClipboardContentType.allCases.map { "\($0.title) \(counts[$0]?.count ?? 0)" }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            LabeledContent(L10n.tr("导入全部后"), value: L10n.tr("%d 条 · %@", preview.requiredCount, bytes(preview.requiredBytes)))
            LabeledContent(L10n.tr("最大保留条数"), value: preview.limits.itemCount == 0
                ? L10n.tr("不限") : L10n.tr("%d 条", preview.limits.itemCount))
            if preview.limits.retentionDays > 0 {
                Text(L10n.tr("已设置保留 %d 天，导入的旧记录也会在后续清理时按原始创建时间处理。", preview.limits.retentionDays))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if preview.needsExpansion {
                Toggle(L10n.tr("提高条数上限并导入全部"), isOn: $viewModel.expandCapacity)
                    .disabled(viewModel.isSaving)
                Text(viewModel.expandCapacity
                     ? L10n.tr("将最大保留条数提高到导入所需数量。清理仍按设置的时间和周期执行。")
                     : L10n.tr("只导入剩余条数内的最近 %d 条，另有 %d 条不导入。", viewModel.importCount, preview.entries.count - viewModel.importCount))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(L10n.tr("保留标题、Pinboard 名称及记录归属，同名分组合并。重复记录补充分组及缺失标题，保留已有标题。不会删除已有历史；不保留分组排序、共享关系及富文本样式。分组记录仍按现有规则清理。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !preview.hasChanges {
                Text(L10n.tr("没有可新增的记录，可以关闭此窗口。"))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func resultContent(_ result: PasteImportResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            let partial = !result.skipped.isEmpty || result.capacitySkipped > 0
            Label(partial ? L10n.tr("部分完成") : L10n.tr("导入完成"), systemImage: partial ? "info.circle.fill" : "checkmark.circle.fill")
                .font(.title2.weight(.semibold)).foregroundStyle(.indigo)
            LabeledContent(L10n.tr("新增记录"), value: L10n.tr("%d 条", result.added))
            LabeledContent(L10n.tr("重复记录"), value: L10n.tr("%d 条", result.duplicates))
            LabeledContent(L10n.tr("条数限制而跳过"), value: L10n.tr("%d 条", result.capacitySkipped))
            LabeledContent(L10n.tr("新增分组"), value: L10n.tr("%d 个", result.groupsAdded))
            LabeledContent(L10n.tr("补充已有记录的分组"), value: L10n.tr("%d 条", result.recordsUpdated))
            LabeledContent(L10n.tr("补充已有记录的标题"), value: L10n.tr("%d 条", result.titlesUpdated))
            Text(L10n.tr("记录按原始时间排列，Paste 原始数据保持不变。"))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .binary).locale(L10n.locale))
    }
}
