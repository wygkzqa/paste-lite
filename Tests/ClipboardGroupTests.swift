import Foundation

@main
@MainActor
struct ClipboardGroupTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLite-group-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ".build/tests/pre-group-history-fixture")
        process.arguments = [root.path]
        try process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        let repository = ClipboardRepository(fileManager: PerformanceFileManager(root: root))
        try await waitUntil { repository.totalCount == 1_205 || repository.errorMessage != nil }
        precondition(repository.errorMessage == nil && repository.groups.isEmpty)
        precondition(repository.items.allSatisfy { ($0.groupIDs ?? []).isEmpty })
        let all = try await repository.query(limit: 210)
        precondition(all.total == 1_205)
        let work = try await repository.saveGroup(name: " 工作 ")
        let snippets = try await repository.saveGroup(name: "Snippets")
        precondition(work.name == "工作")
        do { _ = try await repository.saveGroup(name: "  "); preconditionFailure("Empty name accepted") }
        catch ClipboardGroupError.invalidName {}
        do { _ = try await repository.saveGroup(name: "snippets"); preconditionFailure("Duplicate name accepted") }
        catch ClipboardGroupError.duplicateName {}
        for item in all.items {
            try await repository.setGroups([work.id], for: item.id)
        }
        let target = all.items[0]
        try await repository.setGroups([work.id, snippets.id], for: target.id)
        let first = try await repository.query(ClipboardQuery(group: .group(work.id)))
        let next = try await repository.query(ClipboardQuery(group: .group(work.id)), offset: 200)
        precondition(first.total == 210 && first.items.count == 200 && next.items.count == 10)
        precondition(Set(first.items.map(\.id)).isDisjoint(with: Set(next.items.map(\.id))))
        let ungrouped = try await repository.query(ClipboardQuery(group: .ungrouped))
        precondition(ungrouped.total == 995)
        let search = ClipboardQuery(text: "legacy-tail-needle", type: "text", source: "Legacy Fixture", group: .group(work.id))
        let found = try await repository.query(search)
        precondition(found.total == 1 && found.items[0].id == target.id)
        let detail = try await repository.item(id: target.id)
        precondition(detail!.textContent!.count > 4_000 && Set(detail!.groupIDs!) == [work.id, snippets.id])
        print("PASS: pre-group store migrates with 1,205 entries; groups combine with database search, type/source filters, and 200-entry pagination")

        let reopened = ClipboardRepository(fileManager: PerformanceFileManager(root: root))
        try await waitUntil { reopened.groups.count == 2 }
        let reloaded = try await reopened.item(id: target.id)
        precondition(Set(reloaded!.groupIDs!) == [work.id, snippets.id])
        let renamed = try await repository.saveGroup(id: work.id, name: "项目")
        precondition(renamed.id == work.id)
        let model = ClipboardViewModel(repository: repository)
        model.groupFilter = .group(work.id)
        try await waitUntil { model.resultCount == 210 && !model.isLoading }
        model.selectedID = model.filteredItems.last!.id
        model.moveSelection(by: 1)
        try await waitUntil { model.filteredItems.count == 210 && !model.isLoading }
        precondition(model.selectedID == model.filteredItems[200].id)
        try await repository.deleteGroup(id: work.id)
        try await waitUntil { model.groupFilter == .all && model.resultCount == 1_205 }
        let kept = try await repository.item(id: target.id)
        precondition(kept?.groupIDs == [snippets.id] && repository.totalCount == 1_205)
        let absent = try await repository.query(ClipboardQuery(group: .group(work.id)))
        precondition(absent.total == 0)
        print("PASS: memberships persist; renaming retains identity; deleting a group preserves entries and other memberships; keyboard navigation crosses group pages")

        let capture = ClipboardCapture(type: .text, textContent: "group duplicate fixture", imageData: nil,
            filePaths: [], sourceAppName: "Fixture", sourceBundleID: "test.fixture", capturedAt: Date())
        repository.record(capture)
        try await waitUntil { repository.totalCount == 1_206 }
        let duplicateItem = try await repository.query(ClipboardQuery(text: "group duplicate fixture")).items[0]
        try await repository.setGroups([snippets.id], for: duplicateItem.id)
        let revision = repository.revision
        repository.record(capture)
        try await waitUntil { repository.revision > revision }
        let duplicate = try await repository.item(id: duplicateItem.id)
        precondition(repository.totalCount == 1_206 && duplicate?.groupIDs == [snippets.id])
        _ = try await repository.query(ClipboardQuery(text: "group duplicate fixture", group: .group(snippets.id)))
        try await repository.setGroups([], for: duplicateItem.id)
        let removed = try await repository.query(ClipboardQuery(text: "group duplicate fixture", group: .group(snippets.id)))
        precondition(removed.total == 0)
        var limits = repository.limits
        limits.itemCount = 1
        try await repository.updateLimits(limits)
        precondition(repository.totalCount == 1_206)
        _ = try await repository.cleanHistory()
        let expired = try await repository.item(id: target.id)
        precondition(repository.totalCount == 1 && expired == nil && repository.groups.count == 1)
        print("PASS: deduplication preserves groups; membership changes invalidate cached search; grouped history follows existing cleanup rules without deleting group definitions")
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        precondition(condition(), "Timed out")
    }
}
