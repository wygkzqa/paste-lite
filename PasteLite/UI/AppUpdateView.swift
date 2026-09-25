import SwiftUI

struct AppUpdateView: View {
    @ObservedObject var manager: AppUpdateManager
    @ObservedObject private var settings = AppSettings.shared

    private var title: String {
        switch manager.phase {
        case .idle, .message: L10n.tr("软件更新")
        case .checking: L10n.tr("正在检查更新…")
        case .available: L10n.tr("发现新版本 %@", manager.availableVersion ?? "")
        case .downloading: L10n.tr("正在下载更新…")
        case .extracting: L10n.tr("正在验证并准备更新…")
        case .ready: L10n.tr("更新已准备好")
        case .installing: L10n.tr("正在等待应用退出…")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: "arrow.down.app")
                .font(.title3.weight(.semibold))
            if manager.phase == .checking || manager.phase == .downloading || manager.phase == .extracting || manager.phase == .installing {
                if let progress = manager.progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            if !manager.messageKey.isEmpty {
                Text(L10n.tr(manager.messageKey))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if manager.phase == .available {
                if manager.informationOnly {
                    Text(L10n.tr("此版本需手动下载，请在 GitHub 查看说明。"))
                }
                ScrollView {
                    Text(manager.releaseNotes.isEmpty ? L10n.tr("可在 GitHub 查看完整更新说明。") : manager.releaseNotes)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if manager.phase == .ready {
                Text(L10n.tr("安装将退出并重新打开 Paste Lite。请先完成正在进行的编辑。"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if manager.phase == .installing {
                Text(L10n.tr("如果退出被阻止，请先关闭编辑窗口或等待数据处理完成，再重试。"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !manager.errorDetails.isEmpty {
                DisclosureGroup(L10n.tr("错误详情")) {
                    ScrollView { Text(manager.errorDetails).textSelection(.enabled).font(.caption) }
                        .frame(maxHeight: 100)
                }
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Button(L10n.tr("查看下载页面"), action: manager.openDownloads)
                    .buttonStyle(.link)
                Spacer()
                if manager.phase == .available {
                    Button(L10n.tr("跳过此版本"), action: manager.skipVersion)
                }
                if manager.canClose {
                    Button(L10n.tr(manager.phase == .ready || manager.phase == .downloading || manager.phase == .checking ? "取消" : "关闭"), action: manager.close)
                        .keyboardShortcut(.cancelAction)
                }
                if !manager.informationOnly && (manager.phase == .available || manager.phase == .ready || manager.phase == .installing) {
                    Button(L10n.tr(manager.phase == .available ? "下载更新" : manager.phase == .ready ? "安装并重新启动" : "重试退出"), action: manager.install)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 520, height: 410)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
