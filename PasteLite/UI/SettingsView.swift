import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, history, data, about

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: L10n.tr("通用")
        case .history: L10n.tr("历史")
        case .data: L10n.tr("数据")
        case .about: L10n.tr("关于")
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .history: "clock.arrow.circlepath"
        case .data: "externaldrive"
        case .about: "info.circle"
        }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var section: SettingsSection = .general
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var loginItem = LoginItemManager()
    @ObservedObject var repository: ClipboardRepository
    @ObservedObject var navigation: SettingsNavigation
    let onImport: () -> Void
    let onClearHistory: () async throws -> Void
    @State private var confirmsClearHistory = false
    @State private var clearMessage: String?
    @State private var clearFailed = false

    private func limitRow(_ title: String, unit: String, keyPath: WritableKeyPath<ClipboardLimits, Int>, help: String) -> some View {
        LimitSettingRow(title: title, unit: unit, value: repository.limits[keyPath: keyPath], help: help,
                        enabled: repository.isReady && !repository.isSavingLimits && !repository.isClearingHistory) { value in
            var limits = repository.limits
            limits[keyPath: keyPath] = value
            try await repository.updateLimits(limits)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsSection.allCases, selection: $navigation.section) { section in
                Label(section.title, systemImage: section.symbol)
                    .padding(.vertical, 5)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .padding(.top, 12)
            .frame(width: 164)
            .background(.ultraThinMaterial)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(navigation.section.title)
                    .font(.system(size: 20, weight: .semibold))
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 4)
                Group {
                    switch navigation.section {
                    case .general: Form { generalSettings }
                    case .history: Form { historySettings }
                    case .data: Form { dataSettings }
                    case .about: AboutView()
                    }
                }
                .formStyle(.grouped)
                .id(navigation.section)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 700, height: 540)
        .alert(L10n.tr("清空全部历史？"), isPresented: $confirmsClearHistory) {
            Button(L10n.tr("取消"), role: .cancel) {}
            Button(L10n.tr("清空"), role: .destructive) {
                Task {
                    clearMessage = nil
                    clearFailed = false
                    do {
                        try await onClearHistory()
                        clearMessage = "历史记录已清空。"
                    } catch {
                        clearFailed = true
                        clearMessage = (error as? ClipboardHistoryClearError)?.messageKey ?? "无法清空历史记录，请检查存储权限后重试。"
                    }
                }
            }
        } message: {
            Text(L10n.tr("将永久删除全部历史记录（包括分组内记录）、图片和缩略图，此操作无法撤销。分组、设置、系统当前剪贴板和原始文件会保留。"))
        }
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            loginItem.refresh()
        }
        .onExitCommand { NSApp.keyWindow?.performClose(nil) }
    }

    private var generalSettings: some View {
        Group {
            Section {
                Picker(L10n.tr("语言"), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                    .id(L10n.language)
                }
                Text(L10n.tr("更改后立即生效。跟随系统时，中文系统使用简体中文，其他语言使用英文。"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Picker(L10n.tr("外观"), selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                    .id(L10n.language)
                }
                Picker(L10n.tr("剪贴板布局"), selection: $settings.clipboardLayout) {
                    ForEach(ClipboardLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                    .id(L10n.language)
                }
                Text(L10n.tr("两种布局均使用液态玻璃风格，切换立即生效。旧版 macOS 使用半透明材质。"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle(L10n.tr("开机启动"), isOn: Binding(
                    get: { loginItem.isRequested },
                    set: { enabled in Task { await loginItem.setEnabled(enabled) } }
                ))
                .toggleStyle(.switch)
                .disabled(loginItem.isUpdating)
                Text(L10n.tr("登录 Mac 后自动打开 Paste Lite。"))
                    .font(.callout).foregroundStyle(.secondary)
                if loginItem.status == .requiresApproval {
                    Text(L10n.tr("尚未获准启动，请在系统设置的登录项中允许 Paste Lite。"))
                        .font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if loginItem.status == .notFound {
                    Text(L10n.tr("找不到登录项，请将 Paste Lite 放入 Applications 后重新打开。"))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let message = loginItem.errorMessage {
                    Text(L10n.tr(message))
                        .font(.callout).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if loginItem.status == .requiresApproval || loginItem.errorMessage != nil {
                    Button(L10n.tr("打开登录项设置…")) { loginItem.openSystemSettings() }
                }
            }
            Section(L10n.tr("采集")) {
                limitRow("文本最大收录大小", unit: "MB", keyPath: \.maxTextMB,
                         help: "文本和链接超过此大小时不收录，0 表示不限。")
                limitRow("图片最大收录大小", unit: "MB", keyPath: \.maxImageMB,
                         help: "按保存的 PNG 大小判断，0 表示不限。")
            }
        }
    }

    private var historySettings: some View {
        Section {
            limitRow("保留周期", unit: "天", keyPath: \.retentionDays,
                     help: "按创建时间清理旧记录，0 表示永久保留。")
            limitRow("最大保留条数", unit: "条", keyPath: \.itemCount,
                     help: "清理时保留最新记录，0 表示不限。")
            limitRow("自动清理周期", unit: "小时", keyPath: \.cleanupIntervalHours,
                     help: "0 表示关闭周期清理；启动时仍按保留规则检查一次。")
            Text(L10n.tr("不限制总存储容量。修改保留规则不会立即删除记录。"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dataSettings: some View {
        Group {
            Section {
                LabeledContent(L10n.tr("从 Paste 导入")) {
                    Button(L10n.tr("导入…"), action: onImport)
                        .disabled(!repository.isReady || repository.isSavingLimits || repository.isClearingHistory)
                }
                Text(L10n.tr("导入历史和 Pinboard 分组，保留原始时间与来源应用。"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                LabeledContent(L10n.tr("历史记录"), value: L10n.tr("%d 条", repository.totalCount))
                LabeledContent(L10n.tr("清空剪贴板历史")) {
                    if repository.isClearingHistory {
                        ProgressView().controlSize(.small)
                    }
                    Button(L10n.tr(repository.isClearingHistory ? "正在清空…" : "清空历史…"), role: .destructive) {
                        clearMessage = nil
                        confirmsClearHistory = true
                    }
                    .disabled(!repository.isReady || repository.isSavingLimits || repository.isClearingHistory)
                }
                Text(L10n.tr("删除全部历史和图片，包括分组内记录；保留分组、设置和系统当前剪贴板。"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let clearMessage {
                    Label(L10n.tr(clearMessage), systemImage: clearFailed ? "exclamationmark.circle" : "checkmark.circle")
                        .font(.callout).foregroundStyle(clearFailed ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct LimitSettingRow: View {
    let title: String
    let unit: String
    let value: Int
    let help: String
    let enabled: Bool
    let save: (Int) async throws -> Void
    @State private var draft = ""
    @State private var error: String?
    @State private var saving = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(L10n.tr(title)) {
                HStack(spacing: 6) {
                    TextField("", text: $draft, prompt: Text("0"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(L10n.tr(title))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .focused($focused)
                        .disabled(!enabled || saving)
                        .onSubmit(commit)
                    Text(L10n.tr(unit)).foregroundStyle(.secondary)
                }
            }
            Text(L10n.tr(error ?? help))
                .font(.caption).foregroundStyle(error == nil ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { draft = String(value) }
        .onChange(of: value) { if !focused { draft = String(value) } }
        .onChange(of: focused) { if !focused { commit() } }
        .onDisappear(perform: commit)
    }

    private func commit() {
        guard !saving, enabled else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(text), number <= Int(UInt32.max) else {
            error = "请输入 0 到 4294967295 之间的整数。"
            return
        }
        error = nil
        guard number != value else { draft = String(value); return }
        saving = true
        Task {
            defer { saving = false }
            do { try await save(number); draft = String(number) }
            catch { self.error = "无法保存设置，请重试。" }
        }
    }
}
