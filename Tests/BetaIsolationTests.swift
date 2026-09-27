import AppKit

@main
@MainActor
struct BetaIsolationTests {
    static func main() async throws {
        precondition(AppVariant.isBeta && AppVariant.displayName == "Paste Lite Beta")
        precondition(PanelShortcut.default.displayName == "⇧⌘V")
        precondition(PanelShortcut.default.modifierFlags == [.command, .shift])
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("PasteLite-beta-tests-\(UUID())")
        defer { try? manager.removeItem(at: root) }
        let stable = root.appendingPathComponent("PasteLite")
        try manager.createDirectory(at: stable, withIntermediateDirectories: true)
        // Invalid synthetic legacy files make any accidental read or migration of the stable store fail.
        let sentinel = Data("Synthetic stable data: do not read, migrate, or clear".utf8)
        for name in ["history.store", "history.json", "history-settings.json"] {
            try sentinel.write(to: stable.appendingPathComponent(name))
        }

        let repository = ClipboardRepository(fileManager: PerformanceFileManager(root: root))
        for _ in 0..<1_000 {
            if repository.revision > 0 || repository.errorMessage != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(repository.errorMessage == nil && repository.revision > 0 && repository.totalCount == 0)
        precondition(manager.fileExists(atPath: root.appendingPathComponent("PasteLiteBeta/history.store").path))
        let group = try await repository.saveGroup(name: "Beta only")
        repository.record(ClipboardCapture(type: .text, textContent: "Synthetic Beta history", imageData: nil,
                                          filePaths: [], sourceAppName: "Beta Test", sourceBundleID: "example.beta-test", capturedAt: Date()))
        await repository.prepareForTermination()
        let reopened = ClipboardRepository(fileManager: PerformanceFileManager(root: root))
        let page = try await reopened.query()
        precondition(page.total == 1)
        try await reopened.clearHistory()
        await reopened.reload()
        precondition(reopened.totalCount == 0 && reopened.groups.map(\.id) == [group.id])
        await reopened.prepareForTermination()
        let stableFiles = try manager.contentsOfDirectory(atPath: stable.path)
        precondition(Set(stableFiles) == ["history.store", "history.json", "history-settings.json"])
        for name in stableFiles {
            let data = try Data(contentsOf: stable.appendingPathComponent(name))
            precondition(data == sentinel)
        }
        print("PASS: Beta creates, saves, reopens and clears its own history without touching the synthetic stable store")

        let betaSuite = "PasteLite-beta-preferences-tests-\(UUID())"
        let stableSuite = "PasteLite-stable-preferences-tests-\(UUID())"
        let betaDefaults = UserDefaults(suiteName: betaSuite)!
        let stableDefaults = UserDefaults(suiteName: stableSuite)!
        defer {
            betaDefaults.removePersistentDomain(forName: betaSuite)
            stableDefaults.removePersistentDomain(forName: stableSuite)
        }
        stableDefaults.set("english-stable-sentinel", forKey: "appLanguage")
        let settings = AppSettings(defaults: betaDefaults)
        precondition(settings.panelShortcut == .default)
        settings.language = .chinese
        settings.clipboardLayout = .cards
        precondition(AppSettings(defaults: betaDefaults).clipboardLayout == .cards)
        precondition(stableDefaults.string(forKey: "appLanguage") == "english-stable-sentinel")
        precondition(stableDefaults.object(forKey: "clipboardLayout") == nil)
        print("PASS: Beta defaults to Command-Shift-V and preserves independent preferences")

        let temporary = root.appendingPathComponent("Temporary")
        let expiredBeta = temporary.appendingPathComponent("PasteLiteBeta-import-expired")
        let activeBeta = temporary.appendingPathComponent("PasteLiteBeta-import-active")
        let expiredStable = temporary.appendingPathComponent("PasteLite-import-expired")
        for directory in [expiredBeta, activeBeta, expiredStable] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for directory in [expiredBeta, expiredStable] {
            try manager.setAttributes([.creationDate: Date().addingTimeInterval(-172_800)], ofItemAtPath: directory.path)
        }
        PasteImportService.removeExpiredTemporaryFiles(in: temporary)
        precondition(!manager.fileExists(atPath: expiredBeta.path))
        precondition(manager.fileExists(atPath: activeBeta.path) && manager.fileExists(atPath: expiredStable.path))
        print("PASS: Beta removes only its own expired import staging files")
    }
}
