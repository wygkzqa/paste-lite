import AppKit

private final class URLTestFileManager: FileManager, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        directory == .applicationSupportDirectory ? [root] : super.urls(for: directory, in: domainMask)
    }
}

@main
@MainActor
struct ClipboardURLTests {
    static func main() async throws {
        setbuf(stdout, nil)
        let links = [
            "http://clipboard.account.qa.internal.example.com",
            "https://example.com/path?q=a%20b#section", "HTTPS://EXAMPLE.COM/path",
            "http://localhost:8080/path", "http://127.0.0.1:3000/", "http://[::1]:8080/",
            "https://例子.测试/路径?q=中文", " \nhttps://example.com/with-space\r\n"
        ]
        let texts = [
            "", "Ordinary text", "Visit https://example.com", "https://example.com followed by text",
            "https://example.com\nhttps://example.org", "[Example](https://example.com)",
            "www.example.com", "example.com", "https://", "http:/example.com",
            "https://exa mple.com", "https://example.com/a\u{0}b", "file:///tmp/fixture.txt"
        ]
        for text in links + texts {
            let expected: ClipboardContentType = links.contains(text) ? .url : .text
            let prepared = PreparedCapture.prepare(capture(text))!
            precondition(prepared.type == expected && prepared.textContent == text)
            precondition(prepared.byteCount == Int64(text.utf8.count))
        }
        precondition(PreparedCapture.prepare(capture("mailto:sample@example.com", type: .url))!.type == .url)
        let oversized = "https://example.com/" + String(repeating: "x", count: 1_024 * 1_024)
        precondition(PreparedCapture.prepare(capture(oversized), limits: ClipboardLimits(maxTextMB: 1)) == nil)
        print("PASS: standalone HTTP(S) text recognizes subdomains, case, ports, IPs, Unicode and surrounding whitespace without changing content or size limits; mixed text stays text")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLite-url-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = URLTestFileManager(root: root)
        let repository = ClipboardRepository(fileManager: manager)
        try await waitUntil { repository.isReady || repository.errorMessage != nil }
        precondition(repository.errorMessage == nil)

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let monitor = ClipboardMonitor(repository: repository, pasteboard: board)
        monitor.start()
        defer { monitor.stop() }
        let liveLink = links[0]
        board.clearContents()
        board.setString(liveLink, forType: .string)
        precondition(board.string(forType: .URL) == nil)
        try await waitUntil { repository.totalCount == 1 }
        let captured = repository.items.first!
        precondition(captured.type == .url && captured.textContent == liveLink)
        let group = try await repository.saveGroup(name: "Synthetic links")
        try await repository.setGroups([group.id], for: captured.id)
        try await repository.renameTitle(id: captured.id, title: "Saved link")
        board.clearContents()
        board.setString(liveLink, forType: .URL)
        try await waitUntil { repository.items.first?.id == captured.id && repository.items.first!.lastCopiedAt > captured.lastCopiedAt }
        precondition(repository.totalCount == 1)
        monitor.stop()
        let saved = try await repository.item(id: captured.id)!
        precondition(saved.customTitle == "Saved link" && saved.groupIDs == [group.id])
        precondition(saved.createdAt == captured.createdAt)
        let filtered = try await repository.query(ClipboardQuery(type: "url"))
        precondition(filtered.items.map(\.id) == [captured.id])
        print("PASS: private pasteboard plain-text and native URL captures share one record, preserve title/group/creation time, and appear in link filters")

        let reopened = ClipboardRepository(fileManager: manager)
        try await waitUntil { reopened.isReady }
        let reloaded = try await reopened.item(id: captured.id)
        precondition(reloaded == saved)
        print("PASS: new link classification and metadata persist across reopening")

        let padded = links.last!
        repository.record(capture(padded))
        try await waitUntil { repository.totalCount == 2 }
        let item = try await repository.item(id: repository.items[0].id)!
        let service = PasteService(repository: repository, monitor: monitor, pasteboard: board)
        precondition(service.writeToPasteboard(item))
        precondition(board.string(forType: .string) == padded)
        precondition(board.string(forType: .URL) == padded.trimmingCharacters(in: .whitespacesAndNewlines))
        repository.record(capture("Ordinary text"))
        try await waitUntil { repository.totalCount == 3 }
        let plainItem = repository.items[0]
        try await repository.setGroups([group.id], for: plainItem.id)
        try await repository.editItem(id: plainItem.id, title: "Edited link", textContent: "https://example.com/edited")
        let edited = try await repository.item(id: plainItem.id)!
        precondition(edited.type == .url && edited.groupIDs == [group.id] && edited.customTitle == "Edited link" && edited.createdAt == plainItem.createdAt)
        print("PASS: link paste publishes a valid URL and exact original plain text; editing text into a URL updates stored classification")
    }

    private static func capture(_ text: String, type: ClipboardContentType = .text) -> ClipboardCapture {
        ClipboardCapture(type: type, textContent: text, imageData: nil, filePaths: [],
            sourceAppName: "Fixture", sourceBundleID: "example.fixture", capturedAt: Date())
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        precondition(condition(), "Timed out")
    }
}
