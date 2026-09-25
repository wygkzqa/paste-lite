import AppKit
import Combine
import SwiftUI

// A separate app identity, update key, feed and preferences; never starts clipboard monitoring.
@main
@MainActor
struct AppUpdateHarness {
    static func main() {
        let app = NSApplication.shared
        let delegate = UpdateTestDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class UpdateTestDelegate: NSObject, NSApplicationDelegate {
    private var manager: AppUpdateManager!
    private var subscription: AnyCancellable?
    private var window: NSWindow?
    private var testedBlock = false
    private let mode = Bundle.main.object(forInfoDictionaryKey: "UpdateTestMode") as! String
    private let result = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "UpdateTestResult") as! String)

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "21", mode != "update", mode != "ui" {
            finish("FAIL: installed an update that should have been rejected")
            return
        }
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "21", mode == "update" {
            finish(UserDefaults.standard.string(forKey: "update-test-preference") == "preserved" ? "PASS: installed build 21, relaunched, and preserved preferences" : "FAIL: preferences lost")
            return
        }
        AppSettings.shared.language = .english
        manager = AppUpdateManager()
        if mode == "ui" {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 540),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window?.title = "Paste Lite Update Tests"
            window?.contentView = NSHostingView(rootView: VStack {
                HStack {
                    Button("English") { AppSettings.shared.language = .english }
                    Button("简体中文") { AppSettings.shared.language = .chinese }
                    Button("Light") { AppSettings.shared.appearance = .light }
                    Button("Dark") { AppSettings.shared.appearance = .dark }
                }.padding(.top, 12)
                AboutView(updates: manager)
            })
            window?.center()
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard manager.isConfigured else { finish("FAIL: updater not configured"); return }
        guard !manager.automaticallyChecksForUpdates else { finish("FAIL: automatic checks enabled by default"); return }
        UserDefaults.standard.set("preserved", forKey: "update-test-preference")
        subscription = manager.$phase.sink { [weak self] phase in
            DispatchQueue.main.async { self?.handle(phase) }
        }
        manager.checkForUpdates()
    }

    private func handle(_ phase: AppUpdateManager.Phase) {
        let trace = result.appendingPathExtension("trace")
        let prior = (try? String(contentsOf: trace, encoding: .utf8)) ?? ""
        try? (prior + "\(Date()): \(phase)\n").write(to: trace, atomically: true, encoding: .utf8)
        switch phase {
        case .available:
            manager.install()
        case .ready:
            if !testedBlock {
                testedBlock = true
                manager.installationBlockReason = { "正在处理数据，请稍后再安装更新。" }
                manager.install()
                guard !manager.installationRequested, manager.phase == .ready else {
                    finish("FAIL: install ignored the data/editing guard"); return
                }
                manager.installationBlockReason = { nil }
            }
            if mode == "cancel" {
                manager.close()
            } else if mode == "quit" {
                manager.cancelBeforeTermination { [self] in
                    finish("PASS: quitting cancels the prepared update before termination")
                }
            } else { manager.install() }
        case .idle:
            if mode == "cancel", testedBlock { finish("PASS: cancelling prepared update keeps build 20") }
        case .message:
            if mode == "error", manager.messageKey.hasPrefix("更新未完成") {
                finish("PASS: invalid signature/download rejected without replacing build 20")
            } else if mode == "no-update", manager.messageKey == "当前已是最新可用版本。" {
                finish("PASS: no newer build available")
            } else { finish("FAIL: " + manager.messageKey + " " + manager.errorDetails) }
        default: break
        }
    }

    private func finish(_ text: String) {
        try! text.write(to: result, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}
