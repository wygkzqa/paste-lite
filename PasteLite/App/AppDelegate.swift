import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var repository: ClipboardRepository!
    private var monitor: ClipboardMonitor!
    private var pasteService: PasteService!
    private var hotKeyManager: GlobalHotKeyManager!
    private var panelController: ClipboardPanelController!
    private var statusItem: NSStatusItem!
    private var aboutWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        repository = ClipboardRepository()
        monitor = ClipboardMonitor(repository: repository)
        pasteService = PasteService(repository: repository, monitor: monitor)
        panelController = ClipboardPanelController(
            repository: repository,
            pasteService: pasteService
        )

        configureStatusItem()
        configureHotKey()
        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        hotKeyManager?.unregister()
    }

    @objc private func togglePanel() {
        panelController.toggle()
    }

    @objc private func showAbout() {
        if aboutWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "关于 Paste Lite"
            window.isReleasedWhenClosed = false
            let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
            icon.size = NSSize(width: 512, height: 512)
            window.contentView = NSHostingView(rootView: AboutView(
                icon: icon,
                version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
                build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
            ))
            window.center()
            aboutWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button, let image = NSImage(named: "MenuBarIcon") {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            image.accessibilityDescription = "Paste Lite"
            button.image = image
            button.toolTip = "Paste Lite"
        }

        let menu = NSMenu()
        let openItem = NSMenuItem(
            title: "打开 Paste Lite",
            action: #selector(togglePanel),
            keyEquivalent: "v"
        )
        openItem.keyEquivalentModifierMask = [.command, .shift]
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())

        let aboutItem = NSMenuItem(
            title: "关于 Paste Lite",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(
            title: "退出",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func configureHotKey() {
        hotKeyManager = GlobalHotKeyManager()
        hotKeyManager.action = { [weak self] in
            DispatchQueue.main.async {
                self?.panelController.toggle()
            }
        }
        do {
            try hotKeyManager.register()
        } catch {
            NSLog("Paste Lite: \(error.localizedDescription)")
        }
    }
}
