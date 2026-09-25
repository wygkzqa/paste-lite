import Foundation

@main
@MainActor
struct ClipboardTerminationTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLite-termination-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = PerformanceFileManager(root: root)
        let repository = ClipboardRepository(fileManager: manager)
        for _ in 0..<1_000 {
            if repository.isReady { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(repository.isReady)
        let group = try await repository.saveGroup(name: "Before relaunch")
        for index in 0..<40 {
            repository.record(capture("Queued before quitting \(index)"))
        }
        // No polling or delay: the termination barrier must wait for queued captures itself.
        await repository.prepareForTermination()
        repository.record(capture("Must not be saved after quitting began"))
        do {
            _ = try await repository.saveGroup(name: "Must not be saved")
            preconditionFailure("Writes accepted after termination began")
        } catch ClipboardHistoryClearError.busy {}
        do {
            try await repository.updateLimits(.default)
            preconditionFailure("Settings accepted after termination began")
        } catch ClipboardHistoryClearError.busy {}
        let reopened = ClipboardRepository(fileManager: manager)
        for _ in 0..<1_000 {
            if reopened.isReady { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let page = try await reopened.query()
        await reopened.reload()
        precondition(page.total == 40)
        precondition(reopened.groups.map(\.id) == [group.id])
        precondition(page.items.allSatisfy { $0.textContent?.hasPrefix("Queued before quitting") == true })
        print("PASS: termination drains queued writes, rejects subsequent writes, and preserves history and groups on reopen")
    }

    private static func capture(_ text: String) -> ClipboardCapture {
        ClipboardCapture(type: .text, textContent: text, imageData: nil, filePaths: [],
                         sourceAppName: "Update Test", sourceBundleID: "example.update-test", capturedAt: Date())
    }
}
