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
        case .all: L10n.tr("全部")
        case .text: L10n.tr("文本")
        case .url: L10n.tr("链接")
        case .image: L10n.tr("图片")
        case .file: L10n.tr("文件")
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
    @Published var groupFilter: ClipboardGroupFilter = .all
    @Published var isPresentingOverlay = false
    var isPresentingContextMenu = false
    @Published var selectedID: UUID?
    @Published private(set) var selectedIDs = Set<UUID>()
    @Published private(set) var isSelectingAll = false
    @Published var presentationToken = 0
    @Published var hasAccessibilityPermission = false
    @Published private(set) var filteredItems: [ClipboardItem] = []
    @Published private(set) var resultCount = 0
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var sourceApps: [String] = []
    @Published private(set) var sourceAppNames: [String: String] = [:]
    let keyboardScrollRequests = PassthroughSubject<UUID, Never>()

    var onPaste: ((ClipboardItem) -> Void)?
    var onDismiss: (() -> Void)?
    var onRequestAccessibilityPermission: (() -> Void)?

    let repository: ClipboardRepository
    private var cancellables = Set<AnyCancellable>()
    private var presentationDate = Date()
    private var calendar = Calendar.current
    private var today = Calendar.current.startOfDay(for: Date())
    private var timeLabels: [UUID: (date: Date, label: String)] = [:]
    private var filterTask: Task<Void, Never>?
    private let dateFormatter = DateFormatter()
    private var activeQuery = ClipboardQuery()
    private var displayedQuery: ClipboardQuery?
    private var selectionQuery = ClipboardQuery()
    private var queryGeneration = 0
    private var keyboardAdvance = 0
    private var pasteTask: Task<Void, Never>?
    private var selectionAnchorID: UUID?
    private var keyboardExtendsSelection = false
    private var selectedGroups: [UUID: Set<UUID>] = [:]
    private var selectAllTask: Task<Void, Never>?


    init(repository: ClipboardRepository) {
        self.repository = repository
        resetTimeLabels()
        repository.$sourceApps
            .sink { [weak self] names in
                self?.updateSources(names)
            }
            .store(in: &cancellables)

        repository.$groups
            .sink { [weak self] groups in
                guard let self, case .group(let id) = self.groupFilter else { return }
                if !groups.contains(where: { $0.id == id }) { self.groupFilter = .all }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .appLanguageDidChange)
            .sink { [weak self] _ in
                guard let self else { return }
                self.resetTimeLabels()
                self.updateSources(self.repository.sourceApps)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest4(
            repository.$revision,
            $query
                .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
                .removeDuplicates(),
            $contentFilter.removeDuplicates(),
            $sourceFilter.removeDuplicates()
        )
        .combineLatest($groupFilter.removeDuplicates(), NotificationCenter.default.publisher(for: .appLanguageDidChange).map { _ in () }.prepend(()))
        .sink { [weak self] values, groupFilter, _ in
            let (_, query, contentFilter, sourceFilter) = values
            self?.filter(query: query, contentFilter: contentFilter, sourceFilter: sourceFilter, groupFilter: groupFilter)
        }
        .store(in: &cancellables)
    }

    deinit { filterTask?.cancel(); selectAllTask?.cancel(); pasteTask?.cancel() }

    private func updateSources(_ names: [String]) {
        sourceApps = names
        sourceAppNames = Dictionary(uniqueKeysWithValues: names.map { name in
            (name, name == "未知应用" || name == "Paste（导入）" ? L10n.tr(name) : name)
        })
    }

    private func filter(query: String, contentFilter: ContentFilter, sourceFilter: String, groupFilter: ClipboardGroupFilter) {
        filterTask?.cancel()
        queryGeneration += 1
        keyboardAdvance = 0
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextQuery = ClipboardQuery(
            text: text, type: contentFilter.contentType?.rawValue ?? "", source: sourceFilter,
            matchingTypes: ClipboardContentType.allCases.filter { $0.title.localizedStandardContains(text) }.map(\.rawValue),
            matchingSources: ["未知应用", "Paste（导入）"].filter { L10n.tr($0).localizedStandardContains(text) },
            group: groupFilter
        )
        // A metadata edit should retain loaded pages and the user's visible position.
        let limit = nextQuery == activeQuery ? max(ClipboardRepository.pageSize, filteredItems.count) : ClipboardRepository.pageSize
        if nextQuery != activeQuery {
            selectAllTask?.cancel()
            isSelectingAll = false
        }
        activeQuery = nextQuery
        fetchPage(reset: true, limit: limit)
    }

    func retrySearch() { Task { await repository.reload() } }

    var showsInitialLoading: Bool { isLoading && displayedQuery == nil }

    func loadMoreIfNeeded(_ item: ClipboardItem) {
        if item.id == filteredItems.last?.id { loadNextPage() }
    }

    func loadNextPage() {
        guard !isLoading, filteredItems.count < resultCount else { return }
        fetchPage(reset: false)
    }

    private func fetchPage(reset: Bool, limit: Int = ClipboardRepository.pageSize) {
        let generation = queryGeneration
        let query = activeQuery
        let offset = reset ? 0 : filteredItems.count
        isLoading = true
        errorMessage = nil
        filterTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await repository.query(query, offset: offset, limit: limit)
                guard !Task.isCancelled, generation == queryGeneration else { return }
                // Keep the displayed rows and highlight together until the new result is ready.
                // Select All may already have selected IDs for this query while its page was loading.
                if reset, selectionQuery != query {
                    selectedIDs = []
                    selectedGroups = [:]
                    selectedID = nil
                    selectionAnchorID = nil
                    selectionQuery = query
                } else if reset, !selectedIDs.isSubset(of: Set(page.items.map(\.id))) {
                    let matches = try await repository.selection(for: query)
                    guard !Task.isCancelled, generation == queryGeneration else { return }
                    selectedIDs.formIntersection(matches.keys)
                    selectedGroups = matches.filter { self.selectedIDs.contains($0.key) }
                }
                if reset {
                    if filteredItems != page.items { filteredItems = page.items }
                    displayedQuery = query
                } else { filteredItems.append(contentsOf: page.items) }
                resultCount = page.total
                isLoading = false
                normalizeSelection()
                if !reset, keyboardAdvance > 0, !page.items.isEmpty {
                    let index = min(offset + keyboardAdvance - 1, filteredItems.count - 1)
                    selectForClick(filteredItems[index], extending: keyboardExtendsSelection)
                    keyboardScrollRequests.send(filteredItems[index].id)
                }
                keyboardAdvance = 0
            } catch {
                guard !Task.isCancelled, generation == queryGeneration else { return }
                isLoading = false
                errorMessage = "无法读取历史记录，请重试。"
                keyboardAdvance = 0
            }
        }
    }

    func prepareForPresentation(hasAccessibilityPermission: Bool) {
        cancelPendingPaste()
        keyboardAdvance = 0
        selectAllTask?.cancel()
        isSelectingAll = false
        self.hasAccessibilityPermission = hasAccessibilityPermission
        presentationDate = Date()
        calendar = Calendar.current
        today = calendar.startOfDay(for: presentationDate)
        resetTimeLabels()
        presentationToken += 1
        selectedID = filteredItems.first?.id
        selectedIDs = Set(filteredItems.prefix(1).map(\.id))
        selectedGroups = Dictionary(uniqueKeysWithValues: filteredItems.prefix(1).map { ($0.id, Set($0.groupIDs ?? [])) })
        selectionAnchorID = selectedID
        selectionQuery = displayedQuery ?? activeQuery
    }

    private func resetTimeLabels() {
        timeLabels.removeAll(keepingCapacity: true)
        dateFormatter.locale = L10n.locale
        dateFormatter.calendar = calendar
        dateFormatter.timeZone = calendar.timeZone
    }

    // Compute only displayed rows, always against the last opening time, never the scrolling time.
    func timeLabel(for item: ClipboardItem) -> String {
        if let cached = timeLabels[item.id], cached.date == item.lastCopiedAt { return cached.label }
        let date = item.lastCopiedAt
        let daysAgo = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? 0
        let label: String
        if daysAgo <= 0 {
            let elapsed = max(0, presentationDate.timeIntervalSince(date))
            if elapsed < 60 { label = L10n.tr("刚刚") }
            else if elapsed < 3_600 { label = L10n.tr("%d 分钟前", Int(elapsed / 60)) }
            else { label = L10n.tr("%d 小时前", Int(elapsed / 3_600)) }
        } else if daysAgo == 1 || daysAgo == 2 {
            dateFormatter.dateFormat = "HH:mm"
            label = "\(daysAgo == 1 ? L10n.tr("昨天") : L10n.tr("前天")) \(dateFormatter.string(from: date))"
        } else {
            dateFormatter.dateFormat = calendar.isDate(date, equalTo: presentationDate, toGranularity: .year)
                ? L10n.tr("M月d日 HH:mm") : L10n.tr("yyyy年M月d日 HH:mm")
            label = dateFormatter.string(from: date)
        }
        timeLabels[item.id] = (date, label)
        return label
    }

    func select(_ item: ClipboardItem) {
        keyboardAdvance = 0
        selectAllTask?.cancel()
        isSelectingAll = false
        selectedID = item.id
        selectedIDs = [item.id]
        selectedGroups = [item.id: Set(item.groupIDs ?? [])]
        selectionAnchorID = item.id
        selectionQuery = displayedQuery ?? activeQuery
    }

    func selectForClick(_ item: ClipboardItem, toggling: Bool = false, extending: Bool = false) {
        keyboardAdvance = 0
        selectAllTask?.cancel()
        isSelectingAll = false
        selectionQuery = displayedQuery ?? activeQuery
        if extending,
           let anchor = filteredItems.firstIndex(where: { $0.id == selectionAnchorID }),
           let target = filteredItems.firstIndex(where: { $0.id == item.id }) {
            selectedIDs = Set(filteredItems[min(anchor, target)...max(anchor, target)].map(\.id))
            selectedGroups = Dictionary(uniqueKeysWithValues: filteredItems[min(anchor, target)...max(anchor, target)].map { ($0.id, Set($0.groupIDs ?? [])) })
            selectedID = item.id
        } else if toggling {
            if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
            else { selectedIDs.insert(item.id) }
            selectedGroups[item.id] = selectedIDs.contains(item.id) ? Set(item.groupIDs ?? []) : nil
            selectedID = selectedIDs.contains(item.id) ? item.id : filteredItems.last(where: { selectedIDs.contains($0.id) })?.id
            selectionAnchorID = item.id
        } else { select(item) }
    }

    func selectForContextMenu(_ item: ClipboardItem) {
        keyboardAdvance = 0
        selectAllTask?.cancel()
        isSelectingAll = false
        if selectedIDs.contains(item.id) { selectedID = item.id }
        else { select(item) }
    }

    var selectionForContextMenu: [UUID: Set<UUID>] { selectedGroups }

    func selectAll() {
        // Apply any search text still waiting for its debounce before selecting the result set.
        filter(query: query, contentFilter: contentFilter, sourceFilter: sourceFilter, groupFilter: groupFilter)
        selectAllTask?.cancel()
        isSelectingAll = true
        let query = activeQuery
        selectAllTask = Task { [weak self] in
            guard let self else { return }
            do {
                let matches = try await repository.selection(for: query)
                guard !Task.isCancelled else { return }
                selectedGroups = matches
                selectedIDs = Set(matches.keys)
                selectionQuery = query
                if selectedID == nil { selectedID = filteredItems.first?.id }
                selectionAnchorID = selectedID
                isSelectingAll = false
            } catch {
                guard !Task.isCancelled else { return }
                isSelectingAll = false
                errorMessage = "无法读取历史记录，请重试。"
            }
        }
    }

    func pasteSelected() {
        guard selectedIDs.count == 1, let item = selectedItem else { return }
        paste(item)
    }

    func paste(_ item: ClipboardItem) {
        guard displayedQuery == activeQuery,
              query.trimmingCharacters(in: .whitespacesAndNewlines) == activeQuery.text,
              pasteTask == nil else { return }
        pasteTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            // A cancelled read may finish after a new presentation has started another paste.
            defer { if !Task.isCancelled { pasteTask = nil } }
            do {
                let fullItem = try await repository.item(id: item.id)
                guard !Task.isCancelled, let fullItem else { return }
                onPaste?(fullItem)
            } catch {
                if !Task.isCancelled { errorMessage = "无法读取历史记录，请重试。" }
            }
        }
    }

    func cancelPendingPaste() {
        pasteTask?.cancel()
        pasteTask = nil
    }

    func moveSelection(by offset: Int, extending: Bool = false) {
        let items = filteredItems
        guard !items.isEmpty else {
            selectedID = nil
            selectedIDs = []
            return
        }

        let currentIndex = items.firstIndex(where: { $0.id == selectedID }) ?? 0
        if offset > 0, currentIndex + offset >= items.count, items.count < resultCount {
            keyboardExtendsSelection = extending
            keyboardAdvance += offset
            loadNextPage()
            return
        }
        keyboardAdvance = 0
        let nextIndex = min(max(currentIndex + offset, 0), items.count - 1)
        selectForClick(items[nextIndex], extending: extending)
        keyboardScrollRequests.send(items[nextIndex].id)
    }

    func requestAccessibilityPermission() {
        onRequestAccessibilityPermission?()
    }

    var selectedItem: ClipboardItem? {
        filteredItems.first(where: { $0.id == selectedID })
    }

    private func normalizeSelection() {
        for item in filteredItems where selectedIDs.contains(item.id) { selectedGroups[item.id] = Set(item.groupIDs ?? []) }
        if !selectedIDs.contains(where: { $0 == selectedID }) {
            selectedID = filteredItems.first(where: { selectedIDs.contains($0.id) })?.id
        }
        if selectedIDs.isEmpty, let first = filteredItems.first {
            selectedID = first.id
            selectedIDs = [first.id]
            selectedGroups = [first.id: Set(first.groupIDs ?? [])]
            selectionAnchorID = first.id
        }
    }

}
