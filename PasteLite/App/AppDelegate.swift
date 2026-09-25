import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var repository: ClipboardRepository!
    private var monitor: ClipboardMonitor!
    private var pasteService: PasteService!
    private var hotKeyManager: GlobalHotKeyManager!
    private var panelController: ClipboardPanelController!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let settingsNavigation = SettingsNavigation()
    private var importWindowController: PasteImportWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppSettings.shared.applyAppearance()

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
        Task.detached(priority: .utility) { PasteImportService.removeExpiredTemporaryFiles() }
        NotificationCenter.default.addObserver(self, selector: #selector(updateLanguage), name: .appLanguageDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshSystemLanguage), name: NSLocale.currentLocaleDidChangeNotification, object: nil)

        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let launchReason = launchEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        let launchedInBackground = launchEvent?.eventID == kAEOpenApplication
            && (launchReason == keyAELaunchedAsLogInItem || launchReason == keyAELaunchedAsServiceItem)
        if !launchedInBackground {
            DispatchQueue.main.async { [weak self] in self?.panelController.show() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DispatchQueue.main.async { [weak self] in self?.panelController?.show() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        hotKeyManager?.unregister()
        NotificationCenter.default.removeObserver(self)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppSettings.shared.refreshSystemLanguage()
    }

    @objc private func refreshSystemLanguage() {
        Task { @MainActor in AppSettings.shared.refreshSystemLanguage() }
    }

    @objc private func updateLanguage() {
        configureMenu()
        settingsWindow?.title = L10n.tr("设置")
        importWindowController?.window?.title = L10n.tr("从 Paste 导入")
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 540),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            window.title = L10n.tr("设置")
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(repository: repository, navigation: settingsNavigation, onImport: { [weak self] in
                self?.showImport()
            }, onClearHistory: { [weak self] in
                guard let self else { throw ClipboardHistoryClearError.failed }
                self.panelController.dismiss(reactivateTarget: false)
                defer { ClipboardImageLoader.clearCache() }
                try await self.monitor.clearHistory()
            }))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func togglePanel() {
        panelController.toggle()
    }

    @objc private func showImport() {
        if importWindowController?.window?.isVisible != true {
            importWindowController = PasteImportWindowController(repository: repository) { [weak self] in
                self?.panelController.showImportedHistory()
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        importWindowController?.showWindow(nil)
        importWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        importWindowController?.viewModel.isSaving == true || repository.isClearingHistory || repository.isDeletingItems ? .terminateCancel : .terminateNow
    }

    @objc private func showAbout() {
        settingsNavigation.section = .about
        showSettings()
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

        configureMenu()
    }

    private func configureMenu() {
        let menu = NSMenu()
        let openItem = NSMenuItem(
            title: L10n.tr("打开 Paste Lite"),
            action: #selector(togglePanel),
            keyEquivalent: "v"
        )
        openItem.keyEquivalentModifierMask = [.command, .shift]
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: L10n.tr("设置…"), action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(
            title: L10n.tr("关于 Paste Lite"),
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(
            title: L10n.tr("退出"),
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
