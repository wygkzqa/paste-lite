import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var repository: ClipboardRepository!
    private var monitor: ClipboardMonitor!
    private var pasteService: PasteService!
    private var hotKeyManager: GlobalHotKeyManager!
    private var panelController: ClipboardPanelController!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let settingsNavigation = SettingsNavigation()
    private var importWindowController: PasteImportWindowController?
    private let updates = AppUpdateManager()
    private var updateSubscription: AnyCancellable?
    private var isWaitingToTerminate = false

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
        updates.installationBlockReason = { [weak self] in self?.updateInstallationBlockReason() }
        updateSubscription = updates.$availableVersion.sink { [weak self] version in
            self?.statusItem.menu?.items.first(where: { $0.action == #selector(AppDelegate.checkForUpdates) })?.title =
                version.map { L10n.tr("发现新版本 %@…", $0) } ?? L10n.tr("检查更新…")
        }
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
            window.contentView = NSHostingView(rootView: SettingsView(repository: repository, navigation: settingsNavigation, updates: updates, onImport: { [weak self] in
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
        if isWaitingToTerminate { return .terminateLater }
        guard let repository else { return .terminateNow }
        if !updates.installationRequested, updates.phase != .idle && updates.phase != .message {
            if updates.canClose {
                updates.cancelBeforeTermination { NSApp.terminate(nil) }
            } else {
                updates.showUpdateInFocus()
            }
            return .terminateCancel
        }
        if updates.installationRequested, updateInstallationBlockReason() != nil { return .terminateCancel }
        if importWindowController?.viewModel.isSaving == true || repository.isSavingLimits || repository.isClearingHistory || repository.isDeletingItems {
            return .terminateCancel
        }
        isWaitingToTerminate = true
        monitor.stop()
        hotKeyManager.unregister()
        Task {
            await repository.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func updateInstallationBlockReason() -> String? {
        if panelController?.hasAttachedSheet == true || importWindowController?.window?.isVisible == true || settingsWindow?.attachedSheet != nil {
            return "请先完成并关闭编辑、预览或导入窗口，再安装更新。"
        }
        if repository?.isReady != true || repository.isSavingLimits || repository.isClearingHistory || repository.isDeletingItems {
            return "正在处理数据，请稍后再安装更新。"
        }
        return nil
    }

    @objc private func checkForUpdates() { updates.checkForUpdates() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(checkForUpdates) || updates.canOpenUpdate
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

        let updateItem = NSMenuItem(
            title: updates.availableVersion.map { L10n.tr("发现新版本 %@…", $0) } ?? L10n.tr("检查更新…"),
            action: #selector(checkForUpdates), keyEquivalent: ""
        )
        updateItem.target = self
        menu.addItem(updateItem)

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
