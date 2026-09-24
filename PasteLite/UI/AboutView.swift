import AppKit
import SwiftUI

struct AboutView: View {
    @ObservedObject private var settings = AppSettings.shared
    private let icon: NSImage
    private let version: String
    private let build: String

    init() {
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
