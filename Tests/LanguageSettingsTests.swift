import AppKit

private final class LanguageTestFileManager: FileManager, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        directory == .applicationSupportDirectory ? [root] : super.urls(for: directory, in: domainMask)
    }
}

@main
@MainActor
struct LanguageSettingsTests {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let initialAppearance = app.appearance
        defer { app.appearance = initialAppearance }
        let suiteName = "PasteLite-language-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        precondition(settings.language == .system)
        precondition(settings.clipboardLayout == .list)
        precondition(settings.appearance == .system)
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        for (appearance, name) in [(AppAppearance.dark, NSAppearance.Name.darkAqua), (.light, .aqua)] {
            settings.appearance = appearance
            precondition(AppSettings(defaults: defaults).appearance == appearance)
            precondition(app.appearance?.name == name)
            precondition(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == name,
                         "Existing windows must inherit the selected app appearance")
            app.appearance = nil
            AppSettings(defaults: defaults).applyAppearance()
            precondition(app.appearance?.name == name, "Startup must restore the saved appearance")
        }
        settings.appearance = .system
        precondition(app.appearance == nil && AppSettings(defaults: defaults).appearance == .system)
        defaults.set("unsupported", forKey: "appAppearance")
        let fallback = AppSettings(defaults: defaults)
        precondition(fallback.appearance == .system)
        fallback.applyAppearance()
        precondition(app.appearance == nil, "System mode must clear the override so future system changes can propagate")
        print("PASS: appearance defaults to system, persists both overrides, updates existing windows, restores on startup, and falls back to system")
        settings.clipboardLayout = .cards
        precondition(AppSettings(defaults: defaults).clipboardLayout == .cards)
        settings.clipboardLayout = .list
        precondition(AppSettings(defaults: defaults).clipboardLayout == .list)
        defaults.set("unsupported", forKey: "clipboardLayout")
        precondition(AppSettings(defaults: defaults).clipboardLayout == .list)
        for language in ["zh-CN", "zh-Hans-CN", "zh-Hant-TW", "zh-HK"] {
            precondition(AppLanguage.system.resolved(preferredLanguages: [language]) == .chinese)
        }
        for languages in [["en-US"], ["fr-FR", "zh-CN"], ["ja-JP"], []] {
            precondition(AppLanguage.system.resolved(preferredLanguages: languages) == .english)
        }
        precondition(AppLanguage.chinese.resolved(preferredLanguages: ["en-US"]) == .chinese)
        precondition(AppLanguage.english.resolved(preferredLanguages: ["zh-CN"]) == .english)
        settings.language = .chinese
        precondition(AppSettings(defaults: defaults).language == .chinese)
        settings.language = .english
        precondition(AppSettings(defaults: defaults).language == .english)
        settings.language = .system
        precondition(AppSettings(defaults: defaults).language == .system)
        defaults.set("unsupported", forKey: L10n.languageDefaultsKey)
        precondition(AppSettings(defaults: defaults).language == .system)
        print("PASS: system default, Chinese variants, English fallback, explicit overrides, and preference persistence")

        let english = try translations("en")
        let chinese = try translations("zh-Hans")
        precondition(english.keys.sorted() == chinese.keys.sorted())
        let placeholders = try NSRegularExpression(pattern: "%[@d]")
        for key in english.keys {
            for text in [english[key]!, chinese[key]!] {
                let count = placeholders.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
                let expected = placeholders.numberOfMatches(in: key, range: NSRange(key.startIndex..., in: key))
                precondition(count == expected, "Placeholder mismatch: \(key)")
            }
        }
        setLanguage(.english)
        precondition(L10n.tr("设置…") == "Settings…")
        precondition(L10n.tr("版本 %@（%@）", "1.0", "10") == "Version 1.0 (10)")
        precondition(L10n.tr("已处理 %d / %d 条", 7, 30) == "Processed 7 of 30")
        precondition(PasteImportError.insufficientSpace.localizedDescription.hasPrefix("Not enough disk space"))
        precondition(L10n.tr("附件缺失或过大") == "Missing or oversized attachment")
        precondition(AppAppearance.allCases.map(\.title) == ["System Default", "Dark", "Light"])
        setLanguage(.chinese)
        precondition(L10n.tr("设置…") == "设置…")
        precondition(L10n.tr("已处理 %d / %d 条", 7, 30) == "已处理 7 / 30 条")
        precondition(AppAppearance.allCases.map(\.title) == ["跟随系统", "深色", "浅色"])
        print("PASS: bundled translation coverage, format arguments, and import errors in both languages")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLite-language-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ClipboardRepository(fileManager: LanguageTestFileManager(root: root))
        let model = ClipboardViewModel(repository: repository)
        repository.record(ClipboardCapture(type: .text, textContent: "Sample 中文 content", imageData: nil, filePaths: [], sourceAppName: "Fixture App", sourceBundleID: "example.fixture", capturedAt: Date().addingTimeInterval(-90)))
        waitUntil { repository.items.count == 1 && model.filteredItems.count == 1 }
        model.query = "Sample"
        model.sourceFilter = "Fixture App"
        model.contentFilter = .text
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        model.prepareForPresentation(hasAccessibilityPermission: false)
        let item = repository.items[0]
        let selectedID = model.selectedID
        let token = model.presentationToken
        let chineseTime = model.timeLabel(for: item)
        setLanguage(.english)
        precondition(model.query == "Sample" && model.sourceFilter == "Fixture App" && model.contentFilter == .text)
        precondition(model.selectedID == selectedID && model.presentationToken == token)
        precondition(model.filteredItems.map(\.id) == [item.id])
        precondition(repository.items[0] == item && item.displayTitle == "Sample 中文 content")
        precondition(model.timeLabel(for: item) != chineseTime)
        let englishTime = model.timeLabel(for: item)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(model.timeLabel(for: item) == englishTime)
        setLanguage(.chinese)
        precondition(model.timeLabel(for: item) == chineseTime && model.presentationToken == token)
        precondition(repository.items[0] == item)
        model.sourceFilter = ""
        model.query = "Unknown App"
        repository.record(ClipboardCapture(type: .text, textContent: "Fallback source", imageData: nil, filePaths: [], sourceAppName: "未知应用", sourceBundleID: "", capturedAt: Date()))
        waitUntil { repository.items.count == 2 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(model.filteredItems.isEmpty)
        setLanguage(.english)
        waitUntil { model.filteredItems.count == 1 && model.filteredItems[0].textContent == "Fallback source" }
        precondition(model.filteredItems[0].sourceAppName == "未知应用")
        print("PASS: live language changes preserve history, query, filters, selection, and the presentation time snapshot")
    }

    private static func setLanguage(_ language: AppLanguage) {
        UserDefaults.standard.setVolatileDomain([L10n.languageDefaultsKey: language.rawValue], forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: .appLanguageDidChange, object: nil)
    }

    private static func translations(_ language: String) throws -> [String: String] {
        let path = Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: language + ".lproj")!
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: String]
    }

    private static func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(6)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        precondition(condition(), "Timed out")
    }
}
