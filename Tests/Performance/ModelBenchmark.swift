import Foundation
import Combine

@main
@MainActor
struct ModelBenchmark {
    static func main() async throws {
        setbuf(stdout, nil)
        UserDefaults.standard.setVolatileDomain([L10n.languageDefaultsKey: "en"], forName: UserDefaults.argumentDomain)
        for count in [1_000, 10_000, 50_000] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLite-perf-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let repository = ClipboardRepository(fileManager: PerformanceFileManager(root: root))
            let batch = try PerformanceFixtures.makeBatch(count: count, root: root)
            let preview = try await repository.previewImport(batch)
            _ = try await repository.importBatch(batch, preview: preview, expand: true)
            let loadStart = Date()
            let reopened = ClipboardRepository(fileManager: PerformanceFileManager(root: root))
            while reopened.totalCount != count {
                guard reopened.errorMessage == nil, Date().timeIntervalSince(loadStart) < 60 else {
                    throw NSError(domain: "ModelBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: reopened.errorMessage ?? "Load timed out"])
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            let loadMS = Date().timeIntervalSince(loadStart) * 1_000
            let model = ClipboardViewModel(repository: reopened)
            while model.resultCount != count || model.isLoading {
                guard model.errorMessage == nil, Date().timeIntervalSince(loadStart) < 60 else {
                    throw NSError(domain: "ModelBenchmark", code: 2, userInfo: [NSLocalizedDescriptionKey: model.errorMessage ?? "Initial query timed out"])
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            var opens: [Double] = []
            for _ in 0..<5 {
                let start = Date()
                model.prepareForPresentation(hasAccessibilityPermission: false)
                opens.append(Date().timeIntervalSince(start) * 1_000)
            }
            var searches: [Double] = []
            for query in ["unmatched-needle-xyz", "Record 123", "中文", "Fixture App 19", "image"] {
                let start = Date()
                var received = false
                let subscription = model.$filteredItems.dropFirst().sink { _ in received = true }
                model.query = query
                while !received {
                    guard model.errorMessage == nil, Date().timeIntervalSince(start) < 60 else {
                        throw NSError(domain: "ModelBenchmark", code: 3, userInfo: [NSLocalizedDescriptionKey: model.errorMessage ?? "Search timed out"])
                    }
                    try await Task.sleep(for: .milliseconds(1))
                }
                searches.append(Date().timeIntervalSince(start) * 1_000)
                withExtendedLifetime(subscription) {}
            }
            let titleStart = Date()
            var characters = 0
            for item in repository.items { characters += item.displayTitle.utf8.count }
            let result: [String: Any] = ["count":count,"loaded_rows":reopened.items.count,"reload_ms":loadMS,"open_ms":opens,"search_ms":searches,"search_queries":["unmatched-needle-xyz","Record 123","中文","Fixture App 19","image"],"all_titles_ms":Date().timeIntervalSince(titleStart)*1_000,"title_bytes":characters]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print(String(decoding:data,as:UTF8.self))
            fflush(stdout)
        }
    }
}
