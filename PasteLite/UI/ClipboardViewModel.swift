import Combine
import Foundation

enum ContentFilter: String, CaseIterable, Identifiable {
    case all
    case text
    case url
    case image
    case file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .text: "文本"
        case .url: "链接"
        case .image: "图片"
        case .file: "文件"
        }
    }

    var contentType: ClipboardContentType? {
        switch self {
        case .all: nil
        case .text: .text
        case .url: .url
        case .image: .image
        case .file: .file
        }
    }
}

@MainActor
final class ClipboardViewModel: ObservableObject {
    @Published var query = ""
    @Published var contentFilter: ContentFilter = .all
    @Published var sourceFilter = ""
    @Published var selectedID: UUID?
    @Published var presentationToken = 0
    @Published var hasAccessibilityPermission = false
    @Published private(set) var filteredItems: [ClipboardItem] = []
    @Published private(set) var sourceApps: [String] = []
    @Published private(set) var timeLabels: [UUID: String] = [:]
    @Published private(set) var dateGroups: [UUID: String] = [:]

    var onPaste: ((ClipboardItem) -> Void)?
    var onDismiss: (() -> Void)?
    var onRequestAccessibilityPermission: (() -> Void)?

    let repository: ClipboardRepository
    private var cancellables = Set<AnyCancellable>()

    init(repository: ClipboardRepository) {
        self.repository = repository
        repository.$items
            .sink { [weak self] items in
                self?.sourceApps = Array(
                    Set(items.map(\.sourceAppName).filter { !$0.isEmpty })
                ).sorted()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest4(
            repository.$items,
            $query
                .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
                .removeDuplicates(),
            $contentFilter.removeDuplicates(),
            $sourceFilter.removeDuplicates()
        )
        .map { items, query, contentFilter, sourceFilter in
            items.filter { item in
                let matchesType = contentFilter == .image
                    ? item.hasImage
                    : contentFilter.contentType.map { item.type == $0 } ?? true
                let matchesSource = sourceFilter.isEmpty || item.sourceAppName == sourceFilter
                return matchesType && matchesSource && Self.matches(item, query: query)
            }
        }
        .sink { [weak self] items in
            guard let self else { return }
            self.filteredItems = items
            self.normalizeSelection()
        }
        .store(in: &cancellables)
    }

    func prepareForPresentation(hasAccessibilityPermission: Bool) {
        self.hasAccessibilityPermission = hasAccessibilityPermission

        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone

        // Cache all labels together so filtering and view updates do not recalculate them.
        var labels: [UUID: String] = [:]
        var groups: [UUID: String] = [:]
        for item in repository.items {
            let date = item.lastCopiedAt
            let daysAgo = calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: date), to: today
            ).day ?? 0

            switch daysAgo {
            case ...0: groups[item.id] = "今天"
            case 1: groups[item.id] = "昨天"
            default: groups[item.id] = "更早"
            }

            if daysAgo <= 0 {
                let elapsed = max(0, now.timeIntervalSince(date))
                if elapsed < 60 {
                    labels[item.id] = "刚刚"
                } else if elapsed < 3_600 {
                    labels[item.id] = "\(Int(elapsed / 60)) 分钟前"
                } else {
                    labels[item.id] = "\(Int(elapsed / 3_600)) 小时前"
                }
            } else if daysAgo == 1 || daysAgo == 2 {
                formatter.dateFormat = "HH:mm"
                let day = daysAgo == 1 ? "昨天" : "前天"
                labels[item.id] = "\(day) \(formatter.string(from: date))"
            } else {
                formatter.dateFormat = calendar.isDate(date, equalTo: now, toGranularity: .year)
                    ? "M月d日 HH:mm"
                    : "yyyy年M月d日 HH:mm"
                labels[item.id] = formatter.string(from: date)
            }
        }
        timeLabels = labels
        dateGroups = groups

        presentationToken += 1
        selectedID = filteredItems.first?.id
    }

    func select(_ item: ClipboardItem) {
        selectedID = item.id
    }

    func pasteSelected() {
        guard let item = selectedItem else { return }
        onPaste?(item)
    }

    func pasteItem(at index: Int) {
        let items = filteredItems
        guard items.indices.contains(index) else { return }
        onPaste?(items[index])
    }

    func moveSelection(by offset: Int) {
        let items = filteredItems
        guard !items.isEmpty else {
            selectedID = nil
            return
        }

        let currentIndex = items.firstIndex(where: { $0.id == selectedID }) ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), items.count - 1)
        selectedID = items[nextIndex].id
    }

    func requestAccessibilityPermission() {
        onRequestAccessibilityPermission?()
    }

    var selectedItem: ClipboardItem? {
        filteredItems.first(where: { $0.id == selectedID }) ?? filteredItems.first
    }

    private func normalizeSelection() {
        guard !filteredItems.contains(where: { $0.id == selectedID }) else { return }
        selectedID = filteredItems.first?.id
    }

    private static func matches(_ item: ClipboardItem, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        if item.displayTitle.localizedCaseInsensitiveContains(query)
            || item.type.title.localizedCaseInsensitiveContains(query)
            || (item.hasImage && ClipboardContentType.image.title.localizedCaseInsensitiveContains(query)) {
            return true
        }
        if item.textContent?.localizedCaseInsensitiveContains(query) == true {
            return true
        }
        if item.sourceAppName.localizedCaseInsensitiveContains(query)
            || item.sourceBundleID.localizedCaseInsensitiveContains(query) {
            return true
        }
        return item.filePaths.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
