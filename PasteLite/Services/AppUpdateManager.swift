import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor
final class AppUpdateManager: NSObject, ObservableObject, SPUUserDriver, SPUUpdaterDelegate, NSWindowDelegate {
    enum Phase {
        case idle, checking, available, downloading, extracting, ready, installing, message
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var availableVersion: String?
    @Published private(set) var releaseNotes = ""
    @Published private(set) var progress: Double?
    @Published private(set) var messageKey = ""
    @Published private(set) var errorDetails = ""
    @Published private(set) var informationOnly = false
    @Published private(set) var isConfigured = false
    @Published private(set) var installationRequested = false

    var installationBlockReason: () -> String? = { nil }
    private var updater: SPUUpdater!
    private var window: NSWindow?
    private var subscriptions = Set<AnyCancellable>()
    private var updateReply: ((SPUUserUpdateChoice) -> Void)?
    private var cancellation: (() -> Void)?
    private var acknowledgement: (() -> Void)?
    private var retryTermination: (() -> Void)?
    private var terminationAfterCancellation: (() -> Void)?
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0

    override init() {
        super.init()
        NotificationCenter.default.publisher(for: .appLanguageDidChange)
            .sink { [weak self] _ in self?.window?.title = L10n.tr("软件更新") }
            .store(in: &subscriptions)
        let bundle = Bundle.main
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let feedURL = URL(string: feed)
        var validFeed = feedURL?.scheme == "https"
        #if UPDATE_TESTING
        // Only the separately compiled regression app may use its loopback fixture server.
        validFeed = validFeed || (feedURL?.scheme == "http" && feedURL?.host == "127.0.0.1")
        #endif
        guard let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32,
              validFeed else { return }
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: self, delegate: self)
        do {
            try updater.start()
            isConfigured = true
            updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
            updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
        } catch {
            errorDetails = error.localizedDescription
        }
    }

    var canOpenUpdate: Bool { !isConfigured || canCheckForUpdates || phase != .idle }
    var canClose: Bool { phase != .extracting && phase != .installing }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard isConfigured else { return }
        updater.automaticallyChecksForUpdates = enabled
    }

    func checkForUpdates() {
        guard isConfigured else {
            phase = .message
            messageKey = "此构建尚未配置在线更新，请从 GitHub 下载新版本。"
            presentWindow()
            return
        }
        if phase != .idle {
            presentWindow()
        } else if canCheckForUpdates {
            updater.checkForUpdates()
        }
    }

    func install() {
        guard !informationOnly, phase == .available || phase == .ready || phase == .installing else { return }
        if let reason = installationBlockReason() {
            messageKey = reason
            return
        }
        messageKey = ""
        if phase == .installing {
            retryTermination?()
        } else {
            if phase == .ready { installationRequested = true }
            let reply = updateReply
            updateReply = nil
            reply?(.install)
        }
    }

    func skipVersion() {
        guard phase == .available else { return }
        let reply = updateReply
        updateReply = nil
        reply?(.skip)
    }

    func close() {
        guard canClose else { return }
        let reply = updateReply
        let cancel = cancellation
        let acknowledge = acknowledgement
        let wasReady = phase == .ready
        updateReply = nil
        cancellation = nil
        acknowledgement = nil
        window?.orderOut(nil)
        // Dismissing a prepared Sparkle install can install on quit. Cancel it instead.
        if let reply { reply(wasReady ? .skip : .dismiss) }
        else if let cancel { cancel() }
        else if let acknowledge { acknowledge() }
        else { dismissUpdateInstallation() }
    }

    func cancelBeforeTermination(_ completion: @escaping () -> Void) {
        terminationAfterCancellation = completion
        close()
    }

    func openDownloads() {
        NSWorkspace.shared.open(URL(string: "https://github.com/wygkzqa/paste-lite/releases/latest")!)
    }

    private func presentWindow() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 410),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: AppUpdateView(manager: self))
            window.center()
            self.window = window
        }
        window?.title = L10n.tr("软件更新")
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // The About toggle is the only opt-in entry; never enable profiling or silent installation.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, automaticUpdateDownloading: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        phase = .checking
        messageKey = ""
        errorDetails = ""
        self.cancellation = cancellation
        presentWindow()
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        phase = state.stage == .installing ? .ready : .available
        availableVersion = appcastItem.displayVersionString
        informationOnly = appcastItem.isInformationOnlyUpdate
        releaseNotes = appcastItem.itemDescription ?? ""
        messageKey = ""
        errorDetails = ""
        cancellation = nil
        updateReply = reply
        if state.userInitiated { presentWindow() }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        if let notes = String(data: downloadData.data, encoding: .utf8) {
            releaseNotes = notes
        } else {
            releaseNotes = ""
            messageKey = "无法读取更新说明，可在 GitHub 查看。"
        }
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        messageKey = "无法读取更新说明，可在 GitHub 查看。"
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        phase = .message
        cancellation = nil
        self.acknowledgement = acknowledgement
        let item = (error as NSError).userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem
        if let item, !item.minimumOperatingSystemVersionIsOK || !item.maximumOperatingSystemVersionIsOK || !item.arm64HardwareRequirementIsOK {
            messageKey = "新版本不支持当前 macOS 或 Mac 机型，可在 GitHub 查看系统要求。"
        } else {
            messageKey = "当前已是最新可用版本。"
        }
        presentWindow()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        phase = .message
        messageKey = "更新未完成。请检查网络和安装权限后重试，或从 GitHub 手动下载。"
        errorDetails = error.localizedDescription
        cancellation = nil
        updateReply = nil
        installationRequested = false
        self.acknowledgement = acknowledgement
        presentWindow()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        phase = .downloading
        receivedLength = 0
        expectedLength = 0
        progress = nil
        self.cancellation = cancellation
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
        progress = expectedLength > 0 ? min(Double(receivedLength) / Double(expectedLength), 1) : nil
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        progress = expectedLength > 0 ? min(Double(receivedLength) / Double(expectedLength), 1) : nil
    }

    func showDownloadDidStartExtractingUpdate() {
        phase = .extracting
        progress = nil
        cancellation = nil
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        self.progress = min(max(progress, 0), 1)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        phase = .ready
        progress = nil
        updateReply = reply
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        phase = .installing
        installationRequested = true
        retryTermination = applicationTerminated ? nil : retryTerminatingApplication
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        let terminate = terminationAfterCancellation
        terminationAfterCancellation = nil
        window?.orderOut(nil)
        phase = .idle
        availableVersion = nil
        releaseNotes = ""
        messageKey = ""
        errorDetails = ""
        progress = nil
        informationOnly = false
        installationRequested = false
        updateReply = nil
        cancellation = nil
        acknowledgement = nil
        retryTermination = nil
        if let terminate { DispatchQueue.main.async { terminate() } }
    }

    func showUpdateInFocus() { presentWindow() }
}
