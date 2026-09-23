import AppKit
import SwiftUI

struct AboutView: View {
    let icon: NSImage
    let version: String
    let build: String

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 144, height: 144)
                .padding(.bottom, 8)
                .accessibilityLabel("Paste Lite Logo")

            Text("Paste Lite")
                .font(.system(size: 22, weight: .semibold))

            Text("版本 \(version)（\(build)）")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(width: 320, height: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand {
            NSApp.keyWindow?.performClose(nil)
        }
    }
}
