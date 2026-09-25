import AppKit
import SwiftUI

struct AboutView: View {
    @ObservedObject var updates: AppUpdateManager
    @ObservedObject private var settings = AppSettings.shared
    private let icon: NSImage
    private let version: String
    private let build: String

    init(updates: AppUpdateManager) {
        self.updates = updates
        icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        icon.size = NSSize(width: 512, height: 512)
        version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 100, height: 100)
                .padding(.bottom, 8)
                .accessibilityLabel("Paste Lite Logo")

            Text("Paste Lite")
                .font(.system(size: 18, weight: .semibold))

            Text(L10n.tr("版本 %@（%@）", version, build))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Button(updates.availableVersion.map { L10n.tr("发现新版本 %@…", $0) } ?? L10n.tr("检查更新…"), action: updates.checkForUpdates)
                .disabled(!updates.canOpenUpdate)
                .padding(.top, 4)

            Toggle(L10n.tr("自动检查更新"), isOn: Binding(
                get: { updates.automaticallyChecksForUpdates },
                set: updates.setAutomaticallyChecksForUpdates
            ))
            .toggleStyle(.checkbox)
            .disabled(!updates.isConfigured)
            .padding(.top, 4)

            Text(L10n.tr(updates.isConfigured ? "检查时会连接 GitHub。新版本需你确认后安装。" : "此构建尚未配置在线更新，请从 GitHub 下载新版本。"))
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)

            Text(L10n.tr("Paste Lite 是一款轻量的 macOS 剪贴板管理工具，支持文本、链接、图片和文件记录。通过搜索、分组和快捷粘贴，快速找回并复用复制过的内容。"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
                .padding(.top, 12)

            Link(destination: URL(string: "https://github.com/wygkzqa/paste-lite")!) {
                Label("GitHub", systemImage: "arrow.up.right")
            }
            .font(.system(size: 13))
            .padding(.top, 8)
            .help(L10n.tr("在默认浏览器中打开 Paste Lite 的 GitHub 仓库"))
            .accessibilityLabel(L10n.tr("在 GitHub 上查看 Paste Lite"))
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
