import SwiftUI

@main
struct PasteLiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var settings = AppSettings.shared

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L10n.tr("设置…")) { appDelegate.showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
