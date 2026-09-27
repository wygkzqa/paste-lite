import AppKit
import Foundation

// An optional destination is used by isolated installer tests. Never accept another app name or identity.
@main
struct InstallBeta {
    static let bundleID = "com.local.PasteLite.beta"
    static let appName = "Paste Lite Beta.app"

    static func validate(_ app: URL, newBuild: Bool) throws {
        guard try app.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw failure("Refusing a symbolic link: \(app.path)")
        }
        let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil
        ) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == bundleID else {
            throw failure("Refusing to replace or install an app without the Beta bundle identifier: \(app.path)")
        }
        if newBuild {
            guard info?["PasteLiteBuildChannel"] as? String == "beta",
                  info?["CFBundleExecutable"] as? String == "PasteLite",
                  info?["SUFeedURL"] as? String == "",
                  info?["SUPublicEDKey"] as? String == "" else {
                throw failure("The new app must be a Beta build with no online update feed or key.")
            }
            let signature = Process()
            signature.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            signature.arguments = ["--verify", "--deep", "--strict", app.path]
            try signature.run()
            signature.waitUntilExit()
            guard signature.terminationStatus == 0 else { throw failure("Beta signature verification failed.") }
        }
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "PasteLiteBetaInstaller", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    @MainActor
    static func main() async {
        do {
            guard (2...3).contains(CommandLine.arguments.count) else {
                throw failure("Usage: install-beta <built Beta.app> [destination/Paste Lite Beta.app]")
            }
            let manager = FileManager.default
            let source = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
            let destination = CommandLine.arguments.count == 3
                ? URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
                : manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/\(appName)")
            guard destination.lastPathComponent == appName,
                  source.resolvingSymlinksInPath() != destination.resolvingSymlinksInPath() else {
                throw failure("The destination must be a separate Paste Lite Beta.app.")
            }
            try validate(source, newBuild: true)
            if manager.fileExists(atPath: destination.path) { try validate(destination, newBuild: false) }

            let parent = destination.deletingLastPathComponent()
            try manager.createDirectory(at: parent, withIntermediateDirectories: true)
            // Stage on the same filesystem; the installed app stays intact until the copy is verified.
            let staging = parent.appendingPathComponent(".paste-lite-beta-\(UUID())")
            try manager.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? manager.removeItem(at: staging) }
            let replacement = staging.appendingPathComponent(appName)
            try manager.copyItem(at: source, to: replacement)
            try validate(replacement, newBuild: true)

            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter {
                $0.bundleURL?.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath()
            }
            for app in running {
                guard app.terminate() else { throw failure("Close Beta before replacing it. No app was replaced.") }
            }
            let deadline = Date().addingTimeInterval(20)
            while running.contains(where: { !$0.isTerminated }) {
                guard Date() < deadline else {
                    throw failure("Beta is still running. Finish editing or importing, then retry. No app was replaced.")
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }

            let backup = parent.appendingPathComponent(".paste-lite-beta-backup-\(UUID()).app")
            let hadPreviousApp = manager.fileExists(atPath: destination.path)
            if hadPreviousApp {
                try validate(destination, newBuild: false)
                try manager.moveItem(at: destination, to: backup)
            }
            do {
                try manager.moveItem(at: replacement, to: destination)
            } catch {
                if hadPreviousApp {
                    do { try manager.moveItem(at: backup, to: destination) }
                    catch { throw failure("Restore the previous Beta from \(backup.path): \(error.localizedDescription)") }
                }
                throw error
            }
            if hadPreviousApp { try? manager.removeItem(at: backup) }
            print("Installed \(destination.path). Beta history and preferences were preserved.")
            if !running.isEmpty {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                _ = try await NSWorkspace.shared.openApplication(at: destination, configuration: configuration)
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
