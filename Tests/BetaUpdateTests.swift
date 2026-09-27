import AppKit

@main
@MainActor
struct BetaUpdateTests {
    static func main() {
        _ = NSApplication.shared
        precondition(AppVariant.isBeta)
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as! String
        precondition(Data(base64Encoded: key)?.count == 32)
        precondition(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String == "https://example.invalid/appcast.xml")
        let updates = AppUpdateManager()
        updates.setAutomaticallyChecksForUpdates(true)
        updates.checkForUpdates()
        precondition(!updates.isConfigured && !updates.canOpenUpdate && !updates.canCheckForUpdates)
        precondition(!updates.automaticallyChecksForUpdates && updates.phase == .idle)
        precondition(NSApp.windows.isEmpty)
        print("PASS: Beta never starts online updates, even with a valid release key and HTTPS feed")
    }
}
