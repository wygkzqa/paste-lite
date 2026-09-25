import AppKit
import Combine
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case chinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: L10n.tr("跟随系统")
        case .chinese: "简体中文"
        case .english: "English"
        }
    }

    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard self == .system else { return self }
        return preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? .chinese : .english
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, dark, light

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: L10n.tr("跟随系统")
        case .dark: L10n.tr("深色")
        case .light: L10n.tr("浅色")
        }
    }
}

enum ClipboardLayout: String, CaseIterable, Identifiable {
    case list
    case cards

    var id: String { rawValue }
    var title: String { self == .list ? L10n.tr("列表") : L10n.tr("卡片") }
    var width: CGFloat { self == .list ? 510 : 600 }
    var height: CGFloat { self == .list ? 390 : 290 }
}

extension Notification.Name {
    static let clipboardLayoutDidChange = Notification.Name("PasteLite.clipboardLayoutDidChange")
    static let appLanguageDidChange = Notification.Name("PasteLite.appLanguageDidChange")
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults: UserDefaults
    private var systemLanguage: AppLanguage

    @Published var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            defaults.set(language.rawValue, forKey: L10n.languageDefaultsKey)
            NotificationCenter.default.post(name: .appLanguageDidChange, object: self)
        }
    }

    @Published var clipboardLayout: ClipboardLayout {
        didSet {
            guard clipboardLayout != oldValue else { return }
            defaults.set(clipboardLayout.rawValue, forKey: "clipboardLayout")
            NotificationCenter.default.post(name: .clipboardLayoutDidChange, object: self)
        }
    }

    @Published var appearance: AppAppearance {
        didSet {
            guard appearance != oldValue else { return }
            defaults.set(appearance.rawValue, forKey: "appAppearance")
            applyAppearance()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        clipboardLayout = ClipboardLayout(rawValue: defaults.string(forKey: "clipboardLayout") ?? "") ?? .list
        appearance = AppAppearance(rawValue: defaults.string(forKey: "appAppearance") ?? "") ?? .system
        language = AppLanguage(rawValue: defaults.string(forKey: L10n.languageDefaultsKey) ?? "") ?? .system
        systemLanguage = AppLanguage.system.resolved()
    }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp?.appearance = nil
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        }
    }

    func refreshSystemLanguage() {
        let current = AppLanguage.system.resolved()
        guard current != systemLanguage else { return }
        systemLanguage = current
        if language == .system {
            objectWillChange.send()
            NotificationCenter.default.post(name: .appLanguageDidChange, object: self)
        }
    }
}

/// Resolve language at display time; worker threads can also localize errors safely.
enum L10n {
    static let languageDefaultsKey = "appLanguage"
    private static let bundles: [AppLanguage: Bundle] = [AppLanguage.chinese, .english].reduce(into: [:]) { result, language in
        if let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            result[language] = bundle
        }
    }

    static var language: AppLanguage {
        (AppLanguage(rawValue: UserDefaults.standard.string(forKey: languageDefaultsKey) ?? "") ?? .system).resolved()
    }

    static var locale: Locale { Locale(identifier: language.rawValue) }

    static func tr(_ key: String, _ arguments: CVarArg...) -> String {
        let format = bundles[language]?.localizedString(forKey: key, value: nil, table: nil) ?? key
        return arguments.isEmpty ? format : String(format: format, locale: locale, arguments: arguments)
    }
}
