// run-beta.py appends this harness to AppDelegate.swift in a temporary file.
// Keeping it in the same file permits isolated dependencies without production test hooks.
@MainActor
private final class TerminationTestApplication: NSApplication {
    var didReply = false

    override func reply(toApplicationShouldTerminate shouldTerminate: Bool) {
        precondition(shouldTerminate)
        didReply = true
    }
}

@main
@MainActor
struct BetaTerminationTests {
    static func main() async throws {
        setbuf(stdout, nil)
        let app = TerminationTestApplication.shared as! TerminationTestApplication
        app.setActivationPolicy(.accessory)
        precondition(AppVariant.isBeta)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLite-beta-quit-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let pasteboard = NSPasteboard(name: .init("PasteLite-beta-quit-tests-\(UUID())"))
        defer { pasteboard.releaseGlobally() }

        for filename in ["history-settings.json", "history.json"] {
            let directory = root.appendingPathComponent(filename)
            let dataDirectory = directory.appendingPathComponent(AppVariant.dataDirectoryName)
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            try Data("Invalid synthetic history".utf8).write(to: dataDirectory.appendingPathComponent(filename))
            let repository = ClipboardRepository(fileManager: PerformanceFileManager(root: directory))
            for _ in 0..<500 {
                if repository.errorMessage != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            precondition(repository.errorMessage != nil && !repository.isReady)
            let delegate = AppDelegate()
            delegate.configureTerminationTest(repository: repository, pasteboard: pasteboard)
            app.didReply = false
            precondition(delegate.applicationShouldTerminate(app) == .terminateLater,
                         "A failed history load must not prevent normal Beta termination")
            for _ in 0..<500 {
                if app.didReply { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            precondition(app.didReply && repository.isPreparingToTerminate)
            print("PASS: Beta quits safely after \(filename) fails to load")
        }

        let manager = PerformanceFileManager(root: root.appendingPathComponent("pending-writes"))
        let repository = ClipboardRepository(fileManager: manager)
        for _ in 0..<500 {
            if repository.isReady { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(repository.isReady)
        let delegate = AppDelegate()
        delegate.configureTerminationTest(repository: repository, pasteboard: pasteboard)
        delegate.showTerminationTestSheet()
        precondition(delegate.applicationShouldTerminate(app) == .terminateCancel,
                     "An open edit must still block Beta replacement")
        delegate.closeTerminationTestSheet()
        for index in 0..<40 {
            repository.record(ClipboardCapture(type: .text, textContent: "Queued test capture \(index)", imageData: nil,
                                              filePaths: [], sourceAppName: "Beta Quit Test", sourceBundleID: "example.beta-quit-test",
                                              capturedAt: Date()))
        }
        app.didReply = false
        precondition(delegate.applicationShouldTerminate(app) == .terminateLater)
        for _ in 0..<500 {
            if app.didReply { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(app.didReply)
        let reopened = ClipboardRepository(fileManager: manager)
        let page = try await reopened.query()
        precondition(page.total == 40, "Beta must drain queued writes before replying to the quit request")
        await reopened.prepareForTermination()
        print("PASS: Beta protects open sheets and drains queued writes before quitting")
    }
}

extension AppDelegate {
    fileprivate func configureTerminationTest(repository: ClipboardRepository, pasteboard: NSPasteboard) {
        self.repository = repository
        monitor = ClipboardMonitor(repository: repository, pasteboard: pasteboard)
        hotKeyManager = GlobalHotKeyManager(settings: .shared)
        // Neither clipboard monitoring nor global shortcuts are started in this fixture.
    }

    fileprivate func showTerminationTestSheet() {
        let frame = NSRect(x: -10_000, y: -10_000, width: 300, height: 200)
        settingsWindow = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        settingsWindow?.beginSheet(NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false))
    }

    fileprivate func closeTerminationTestSheet() {
        if let sheet = settingsWindow?.attachedSheet {
            settingsWindow?.endSheet(sheet)
            sheet.orderOut(nil)
        }
        settingsWindow?.orderOut(nil)
        settingsWindow = nil
    }
}
